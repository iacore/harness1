//! Everything the UI needs from the terminal: raw mode, the terminal's size,
//! reading keys, writing bytes, and the escape sequences. This file is the only
//! place that touches a tty.
//!
//! kitty is the only terminal targeted, so the sequences are kitty's and no
//! other terminal is detected or consulted. The scrollback erase is `CSI 3 J`,
//! "Erase Saved Lines" — the same thing kitty's `clear_terminal scrollback`
//! action does. `main_tui.zig` holds the editor and none of this.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const stdin = posix.STDIN_FILENO;
pub const stdout = posix.STDOUT_FILENO;

// ── Escape sequences ────────────────────────────────────────────────────────

pub const enter_alternate_screen = "\x1b[?1049h";
pub const leave_alternate_screen = "\x1b[?1049l";
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";
pub const erase_screen = "\x1b[2J";
pub const erase_scrollback = "\x1b[3J";
pub const cursor_home = "\x1b[H";

// ── Writing ─────────────────────────────────────────────────────────────────

/// Writes raw bytes to the terminal.
pub fn write(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes.len - offset;
        const count = linux.write(stdout, bytes.ptr + offset, remaining);
        // The syscall reports an error as a negated errno, which is wider than
        // the request and so cannot be mistaken for a count.
        if (count == 0 or count > remaining) return error.WriteFailed;
        offset += count;
    }
}

/// Writes a formatted string to the terminal. A write that fails is dropped:
/// the terminal is where the UI would have reported it.
pub fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    write(text) catch {};
}

/// Writes every part in one `writev`, so the terminal takes them as a single
/// transaction and never paints a state that lies between them. More parts than
/// the batch holds, or a short write, fall back to plain writes.
pub fn writeParts(parts: []const []const u8) !void {
    if (parts.len == 0) return;
    var iov: [8]posix.iovec_const = undefined;
    if (parts.len > iov.len) {
        for (parts) |part| try write(part);
        return;
    }
    var total: usize = 0;
    for (parts, 0..) |part, i| {
        iov[i] = .{ .base = part.ptr, .len = part.len };
        total += part.len;
    }
    const count = linux.writev(stdout, &iov, parts.len);
    if (count == 0 or count > total) return error.WriteFailed;
    if (count == total) return;
    // A partial writev leaves a tail; finish it part by part.
    var written = count;
    for (parts) |part| {
        if (written >= part.len) {
            written -= part.len;
            continue;
        }
        try write(part[written..]);
        written = 0;
    }
}

// ── The terminal itself ─────────────────────────────────────────────────────

/// The terminal's state as it was before raw mode, kept so it can be put back.
pub const RawMode = struct {
    saved: posix.termios,

    /// Restores what the terminal had before `startRaw`.
    pub fn deinit(self: RawMode) void {
        posix.tcsetattr(stdin, .NOW, self.saved) catch {};
    }
};

/// Puts stdin in raw mode: no canonical line editing, no echo, no signals, one
/// byte per read, no read timeout. Fails when stdin is not a terminal.
pub fn startRaw() !RawMode {
    const saved = try posix.tcgetattr(stdin);
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    // Ctrl-S and Ctrl-Q are flow control unless IXON is off, and the UI wants
    // them as keys.
    raw.iflag.IXON = false;
    raw.iflag.IXOFF = false;
    raw.cc[@intCast(@backingInt(linux.V.MIN))] = 1;
    raw.cc[@intCast(@backingInt(linux.V.TIME))] = 0;
    try posix.tcsetattr(stdin, .NOW, raw);
    return .{ .saved = saved };
}

pub const Size = struct { rows: usize, cols: usize };

/// The terminal's size in cells, or null when it cannot be read.
pub fn size() ?Size {
    var window: posix.winsize = undefined;
    const request = @as(u32, @intCast(linux.T.IOCGWINSZ));
    if (linux.ioctl(stdout, request, @intFromPtr(&window)) != 0) return null;
    if (window.row == 0 or window.col == 0) return null;
    return .{ .rows = window.row, .cols = window.col };
}

// ── Reading ─────────────────────────────────────────────────────────────────

pub const Key = union(enum) {
    byte: u8,
    left,
    right,
    up,
    down,
    home,
    end,
    delete,
    escape,
    eof,
    unknown,
};

/// Reads one key. Escape sequences are read whole, with a short wait for the
/// bytes that follow `ESC` so a lone Escape does not block the UI.
pub fn readKey() !Key {
    var byte: [1]u8 = undefined;
    if (!try readByte(&byte)) return .eof;
    if (byte[0] != 0x1b) return .{ .byte = byte[0] };

    var first: [1]u8 = undefined;
    if (!try readWithin(20, &first)) return .escape;
    if (first[0] != '[' and first[0] != 'O') return .escape;
    var second: [1]u8 = undefined;
    if (!try readWithin(20, &second)) return .unknown;
    return switch (second[0]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '3' => blk: {
            var tilde: [1]u8 = undefined;
            if (try readWithin(20, &tilde) and tilde[0] == '~') break :blk .delete;
            break :blk .unknown;
        },
        else => .unknown,
    };
}

fn readWithin(timeout_ms: i32, byte: *[1]u8) !bool {
    var fds = [_]posix.pollfd{.{ .fd = stdin, .events = posix.POLL.IN, .revents = 0 }};
    if (try posix.poll(&fds, timeout_ms) == 0) return false;
    return readByte(byte);
}

fn readByte(byte: *[1]u8) !bool {
    return try posix.read(stdin, byte) == 1;
}

// ── Text ────────────────────────────────────────────────────────────────────
//
// Editing has to move and delete by what the user sees, not by byte: a
// combining mark rides with its base, and a wide character takes two columns.
// These are the pieces for that — a grapheme cluster, and the columns it
// occupies. They are the terminal's facts, which is why they live here; the
// editor that uses them is `tui.zig`.
//
// A cluster is a base codepoint followed by everything that extends it:
// combining marks, variation selectors, emoji modifiers, an emoji tag sequence,
// a zero-width joiner and what it joins, or a second regional indicator.

const Codepoint = struct { cp: u21, len: usize };

fn decode(text: []const u8, index: usize) ?Codepoint {
    if (index >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return .{ .cp = text[index], .len = 1 };
    if (index + len > text.len) return .{ .cp = text[index], .len = 1 };
    const cp = std.unicode.utf8Decode(text[index..][0..len]) catch return .{ .cp = text[index], .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// The bytes of the grapheme cluster that starts at `index`.
pub fn clusterLen(text: []const u8, index: usize) usize {
    const first = decode(text, index) orelse return if (index < text.len) 1 else 0;
    var i = index + first.len;
    if (regionalIndicator(first.cp)) {
        if (decode(text, i)) |second| {
            if (regionalIndicator(second.cp)) i += second.len;
        }
        return i - index;
    }
    while (i < text.len) {
        const cp = decode(text, i) orelse break;
        if (zeroWidth(cp.cp)) {
            i += cp.len;
            continue;
        }
        if (cp.cp == 0x200D) {
            // A joiner keeps the next codepoint in the cluster.
            i += cp.len;
            if (decode(text, i)) |joined| i += joined.len;
            continue;
        }
        if (cp.cp >= 0x1F3FB and cp.cp <= 0x1F3FF) {
            // Skin-tone modifier.
            i += cp.len;
            continue;
        }
        break;
    }
    return i - index;
}

/// The byte index of the cluster after the one at `index`.
pub fn nextGrapheme(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const len = clusterLen(text, index);
    return index + @max(len, 1);
}

/// The byte index of the cluster before the one at `index`. It scans from the
/// start of `from` — a line start the caller knows — which keeps it correct
/// over the joining rules without a backward parser.
pub fn prevGrapheme(text: []const u8, from: usize, index: usize) usize {
    if (index <= from) return from;
    var previous: usize = from;
    var i: usize = from;
    while (i < index) {
        previous = i;
        i = nextGrapheme(text, i);
    }
    return previous;
}

/// The columns the cluster at `index` occupies: none for a combining run, two
/// for a wide character or an emoji (the wide set, or anything asking for the
/// emoji presentation with U+FE0F), one otherwise.
pub fn clusterWidth(text: []const u8, index: usize) usize {
    const first = decode(text, index) orelse return 1;
    if (zeroWidth(first.cp)) return 0;
    const cluster = text[index..][0..clusterLen(text, index)];
    if (std.mem.indexOfScalar(u21, &codepointsOf(cluster), 0xFE0F) != null) return 2;
    if (first.cp >= 0x1F300 and first.cp <= 0x1FAFF) return 2;
    return if (wide(first.cp)) 2 else 1;
}

/// The columns `text` occupies.
pub fn displayWidth(text: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        total += clusterWidth(text, i);
        i = nextGrapheme(text, i);
    }
    return total;
}

fn codepointsOf(cluster: []const u8) [16]u21 {
    var buffer: [16]u21 = @splat(0);
    var count: usize = 0;
    var i: usize = 0;
    while (i < cluster.len and count < buffer.len) {
        const cp = decode(cluster, i) orelse break;
        buffer[count] = cp.cp;
        count += 1;
        i += cp.len;
    }
    return buffer;
}

fn regionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn zeroWidth(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x05BF, 0x05C1...0x05C2, 0x05C4...0x05C5 => true,
        0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E4, 0x06E7...0x06E8, 0x06EA...0x06ED => true,
        0x0711, 0x0730...0x074A, 0x07A6...0x07B0, 0x07EB...0x07F3 => true,
        0x0816...0x0819, 0x081B...0x0823, 0x0825...0x0827, 0x0829...0x082D, 0x0859...0x085B => true,
        0x08D4...0x08E1, 0x08E3...0x0902, 0x093A, 0x093C, 0x0941...0x0948, 0x094D, 0x0951...0x0957, 0x0962...0x0963 => true,
        0x0E31, 0x0E34...0x0E3A, 0x0E47...0x0E4E, 0x0EB1, 0x0EB4...0x0EB9, 0x0EBB...0x0EBC, 0x0EC8...0x0ECD => true,
        0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF => true,
        0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF => true,
        0xFE00...0xFE0F, 0xFE20...0xFE2F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

fn wide(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115F => true,
        0x2E80...0x2EFF, 0x2F00...0x2FDF, 0x2FF0...0x2FFF => true,
        0x3000...0x303E, 0x3041...0x33FF => true,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF => true,
        0xA960...0xA97F, 0xAC00...0xD7A3 => true,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F => true,
        0xFF00...0xFF60, 0xFFE0...0xFFE6 => true,
        0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF => true,
        0x20000...0x2FFFD, 0x30000...0x3FFFD => true,
        else => false,
    };
}