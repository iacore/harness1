//! The run1 client: a small terminal editor for a multi-line prompt, with
//! `:`-commands. When stdin is not a terminal it prints the harness system
//! prompt instead, so a pipe keeps the old behaviour.
//!
//!   :q            quit
//!   :prompt       load the harness system prompt into the editor
//!   :clear        empty the editor
//!
//! Keys: printable text and Enter edit the buffer, Backspace and Delete remove,
//! the arrows and Home/End move, `:` opens the command line, Ctrl-C quits.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const run1 = @import("run1");

const stdin = posix.STDIN_FILENO;
const stdout = posix.STDOUT_FILENO;

pub fn main(init: std.process.Init) !void {
    var editor: Editor = .{ .gpa = init.gpa };
    defer editor.deinit();
    if (init.environ_map.get("COLUMNS")) |value| editor.cols = std.fmt.parseInt(usize, value, 10) catch 80;
    if (init.environ_map.get("LINES")) |value| editor.rows = std.fmt.parseInt(usize, value, 10) catch 24;

    // No terminal to draw on: the pipe path keeps the old behaviour.
    const saved = posix.tcgetattr(stdin) catch return printPrompt(init);
    defer posix.tcsetattr(stdin, .NOW, saved) catch {};
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.cc[@intCast(@backingInt(linux.V.MIN))] = 1;
    raw.cc[@intCast(@backingInt(linux.V.TIME))] = 0;
    try posix.tcsetattr(stdin, .NOW, raw);

    writeAll("\x1b[?1049h") catch {};
    defer writeAll("\x1b[?1049l\x1b[?25h") catch {};

    editor.render();
    while (true) {
        const key = readKey() catch break;
        if (try editor.handle(key)) break;
        editor.render();
    }
}

/// The non-interactive path: the whole system prompt, as before the TUI.
fn printPrompt(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &buffer);
    try run1.system_prompt.systemPrompt(&out.interface);
    try out.flush();
}

const Editor = struct {
    gpa: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    command: std.ArrayList(u8) = .empty,
    mode: Mode = .edit,
    status: []const u8 = "",
    cols: usize = 80,
    rows: usize = 24,
    /// The buffer line drawn on the editor's first row.
    top: usize = 0,

    const Mode = enum { edit, command };

    fn deinit(self: *Editor) void {
        self.buffer.deinit(self.gpa);
        self.command.deinit(self.gpa);
    }

    fn handle(self: *Editor, key: Key) !bool {
        return switch (self.mode) {
            .edit => self.editKey(key),
            .command => self.commandKey(key),
        };
    }

    fn editKey(self: *Editor, key: Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                ':' => {
                    self.mode = .command;
                    self.command.clearRetainingCapacity();
                },
                0x7f, 0x08 => self.backspace(),
                '\r', '\n' => self.insert('\n'),
                else => if (byte >= 0x20) self.insert(byte),
            },
            .left => if (self.cursor > 0) {
                self.cursor -= 1;
            },
            .right => if (self.cursor < self.buffer.items.len) {
                self.cursor += 1;
            },
            .up => self.moveLine(-1),
            .down => self.moveLine(1),
            .home => self.cursor = self.lineStart(self.lineOf(self.cursor)),
            .end => self.cursor = self.lineEnd(self.lineOf(self.cursor)),
            .delete => if (self.cursor < self.buffer.items.len) {
                _ = self.buffer.orderedRemove(self.cursor);
            },
            .escape, .eof, .unknown => {},
        }
        return false;
    }

    fn commandKey(self: *Editor, key: Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                0x7f, 0x08 => if (self.command.items.len > 0) {
                    _ = self.command.pop();
                },
                '\r', '\n' => return self.run(),
                else => if (byte >= 0x20) self.command.append(self.gpa, byte) catch {},
            },
            .escape => self.mode = .edit,
            else => {},
        }
        return false;
    }

    fn run(self: *Editor) bool {
        const command = std.mem.trim(u8, self.command.items, " \t");
        self.mode = .edit;
        if (eq(command, "q") or eq(command, "quit") or eq(command, "exit")) return true;
        if (eq(command, "prompt") or eq(command, "system")) {
            self.loadSystemPrompt() catch {
                self.status = "could not load the system prompt";
            };
        } else if (eq(command, "clear")) {
            self.buffer.clearRetainingCapacity();
            self.cursor = 0;
            self.top = 0;
            self.status = "cleared";
        } else if (command.len == 0) {
            self.status = "";
        } else {
            self.status = "unknown command";
        }
        return false;
    }

    fn loadSystemPrompt(self: *Editor) !void {
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try run1.system_prompt.systemPrompt(&out.writer);
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.gpa, out.written());
        self.cursor = 0;
        self.top = 0;
        self.status = "loaded the harness system prompt";
    }

    fn insert(self: *Editor, byte: u8) void {
        self.buffer.insert(self.gpa, self.cursor, byte) catch return;
        self.cursor += 1;
    }

    fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        _ = self.buffer.orderedRemove(self.cursor - 1);
        self.cursor -= 1;
    }

    fn moveLine(self: *Editor, delta: isize) void {
        const line = self.lineOf(self.cursor);
        const target = @as(isize, @intCast(line)) + delta;
        if (target < 0 or target >= @as(isize, @intCast(self.lineCount()))) return;
        const column = self.colOf(self.cursor);
        const start = self.lineStart(@intCast(target));
        const end = self.lineEnd(@intCast(target));
        self.cursor = @min(start + column, end);
    }

    fn lineCount(self: *Editor) usize {
        var count: usize = 1;
        for (self.buffer.items) |byte| {
            if (byte == '\n') count += 1;
        }
        return count;
    }

    fn lineOf(self: *Editor, index: usize) usize {
        var line: usize = 0;
        for (self.buffer.items[0..@min(index, self.buffer.items.len)]) |byte| {
            if (byte == '\n') line += 1;
        }
        return line;
    }

    fn lineStart(self: *Editor, line: usize) usize {
        if (line == 0) return 0;
        var seen: usize = 0;
        for (self.buffer.items, 0..) |byte, i| {
            if (byte == '\n') {
                seen += 1;
                if (seen == line) return i + 1;
            }
        }
        return self.buffer.items.len;
    }

    fn lineEnd(self: *Editor, line: usize) usize {
        const start = self.lineStart(line);
        if (std.mem.indexOfScalar(u8, self.buffer.items[start..], '\n')) |offset| return start + offset;
        return self.buffer.items.len;
    }

    fn colOf(self: *Editor, index: usize) usize {
        return index - self.lineStart(self.lineOf(index));
    }

    /// Draws the status row, the visible buffer, the command row, and the
    /// cursor. Long lines wrap, so the viewport is counted in display rows.
    fn render(self: *Editor) void {
        if (terminalSize()) |size| {
            self.rows = size.rows;
            self.cols = size.cols;
        }
        const width = self.columns();
        const height = if (self.rows > 3) self.rows - 2 else 1;
        const cursor = self.cursorDisplay();
        if (cursor.row < self.top) self.top = cursor.row;
        if (cursor.row >= self.top + height) self.top = cursor.row + 1 - height;

        writeAll("\x1b[2J\x1b[H") catch {};
        print("\x1b[7m run1 \x1b[0m {s}  {d} lines  {s} \x1b[K", .{ @tagName(self.mode), self.lineCount(), self.status });

        var display: usize = 0;
        var drawn: usize = 0;
        var line: usize = 0;
        outer: while (line < self.lineCount()) : (line += 1) {
            const start = self.lineStart(line);
            const end = self.lineEnd(line);
            const rows = rowsFor(end - start, width);
            var row: usize = 0;
            while (row < rows) : (row += 1) {
                if (display < self.top) {
                    display += 1;
                    continue;
                }
                if (drawn >= height) break :outer;
                const from = start + row * width;
                print("\x1b[{d};1H\x1b[K", .{2 + drawn});
                writeAll(self.buffer.items[from..@min(end, from + width)]) catch {};
                drawn += 1;
                display += 1;
            }
        }

        print("\x1b[{d};1H\x1b[K", .{self.rows});
        if (self.mode == .command) {
            print(":{s}", .{self.command.items});
            print("\x1b[{d};{d}H", .{ self.rows, self.command.items.len + 2 });
        } else {
            print("\x1b[{d};{d}H", .{ 2 + (cursor.row - self.top), cursor.col + 1 });
        }
    }

    /// The columns a line may use, never zero.
    fn columns(self: *Editor) usize {
        return if (self.cols > 1) self.cols else 1;
    }

    /// Where the cursor sits in display cells, with long lines wrapped.
    fn cursorDisplay(self: *Editor) struct { row: usize, col: usize } {
        const width = self.columns();
        var row: usize = 0;
        const cursor_line = self.lineOf(self.cursor);
        var line: usize = 0;
        while (line < cursor_line) : (line += 1) {
            row += rowsFor(self.lineEnd(line) - self.lineStart(line), width);
        }
        const column = self.colOf(self.cursor);
        return .{ .row = row + column / width, .col = column % width };
    }
};

const Key = union(enum) {
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

fn readKey() !Key {
    var byte: [1]u8 = undefined;
    if (!try readerRead(&byte)) return .eof;
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
    return readerRead(byte);
}

fn readerRead(byte: *[1]u8) !bool {
    const count = try posix.read(stdin, byte);
    return count == 1;
}

fn writeAll(bytes: []const u8) !void {
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

fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    writeAll(text) catch {};
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The display rows a line of `length` bytes takes at `width` columns.
fn rowsFor(length: usize, width: usize) usize {
    return if (length == 0) 1 else (length + width - 1) / width;
}

/// The terminal's size, or null when it cannot be read.
fn terminalSize() ?struct { rows: usize, cols: usize } {
    var size: posix.winsize = undefined;
    const request = @as(u32, @intCast(linux.T.IOCGWINSZ));
    if (linux.ioctl(stdout, request, @intFromPtr(&size)) != 0) return null;
    if (size.row == 0 or size.col == 0) return null;
    return .{ .rows = size.row, .cols = size.col };
}
