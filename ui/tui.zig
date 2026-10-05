//! The TUI mode: a terminal editor with a multi-line prompt buffer and a
//! separate command buffer. Tab switches between them, and Tab again switches
//! back; the two never share text.
//!
//!   Tab           switch between the prompt and the command line
//!   :             also opens the command line
//!   Enter         a newline on the prompt; runs the command on the command line
//!   q, quit, exit leave             (a command)
//!   prompt, system load the harness system prompt into the prompt buffer
//!   clear         empty the prompt buffer
//!   ipython, python open an embedded IPython session; run1 exits when it ends
//!
//! Editing goes by grapheme, not by byte: Backspace and Delete remove a whole
//! cluster, the arrows step one, Home and End go to the line's ends, and
//! columns are counted in the cells kitty draws — so a combining mark stays
//! with its base and a wide character takes two columns. Long lines wrap. Every
//! terminal call is `kitty.zig`.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const kitty = @import("kitty.zig");
const python = @import("python.zig");

pub fn run(init: std.process.Init) !void {
    var editor: Editor = .{ .gpa = init.gpa };
    defer editor.deinit();
    if (init.environ_map.get("COLUMNS")) |value| editor.cols = std.fmt.parseInt(usize, value, 10) catch 80;
    if (init.environ_map.get("LINES")) |value| editor.rows = std.fmt.parseInt(usize, value, 10) catch 24;

    // No terminal to draw on: the caller falls back to the CLI.
    var terminal = Terminal.open() catch return error.NotATerminal;
    defer terminal.close();

    editor.render();
    while (true) {
        const key = kitty.readKey() catch break;
        if (try editor.handle(key)) break;
        if (editor.embed_requested) {
            editor.embed_requested = false;
            // IPython needs the terminal back, and it ends the program: a
            // normal return from `embed` — Ctrl-D, or `exit()` — is run1's own
            // normal exit. Only a session that could not start comes back.
            terminal.close();
            if (python.embed() == 0) return;
            terminal = try Terminal.open();
            editor.status = "IPython did not run";
        }
        editor.render();
    }
}

/// Raw mode and the alternate screen, held together so they leave together
/// when an IPython session borrows the terminal.
const Terminal = struct {
    raw: kitty.RawMode,

    fn open() !Terminal {
        const raw = try kitty.startRaw();
        kitty.write(kitty.enter_alternate_screen) catch {};
        return .{ .raw = raw };
    }

    fn close(self: Terminal) void {
        kitty.write(kitty.leave_alternate_screen ++ kitty.show_cursor) catch {};
        self.raw.deinit();
    }
};

const Editor = struct {
    gpa: std.mem.Allocator,
    /// The prompt being edited.
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    /// The command line, kept apart from the prompt and left in place while the
    /// prompt is shown.
    command: std.ArrayList(u8) = .empty,
    mode: Mode = .prompt,
    status: []const u8 = "",
    /// Set by the `ipython` command, read by the loop, which hands the
    /// terminal to the embedded session.
    embed_requested: bool = false,
    cols: usize = 80,
    rows: usize = 24,
    /// The display row drawn on the editor's first row.
    top: usize = 0,

    const Mode = enum { prompt, command };

    fn deinit(self: *Editor) void {
        self.buffer.deinit(self.gpa);
        self.command.deinit(self.gpa);
    }

    fn handle(self: *Editor, key: kitty.Key) !bool {
        return switch (self.mode) {
            .prompt => self.promptKey(key),
            .command => self.commandKey(key),
        };
    }

    fn promptKey(self: *Editor, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                9, ':' => self.mode = .command, // Tab, and `:` for a keyboard without one
                0x7f, 0x08 => self.backspace(),
                '\r', '\n' => self.insertByte('\n'),
                else => if (byte >= 0x20) self.insertByte(byte),
            },
            .left => self.cursor = self.steppedBack(self.cursor),
            .right => self.cursor = self.steppedForward(self.cursor),
            .up => self.moveLine(-1),
            .down => self.moveLine(1),
            .home => self.cursor = self.lineStart(self.lineOf(self.cursor)),
            .end => self.cursor = self.lineEnd(self.lineOf(self.cursor)),
            .delete => self.deleteCluster(),
            .escape, .eof, .unknown => {},
        }
        return false;
    }

    fn commandKey(self: *Editor, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                9 => self.mode = .prompt, // Tab switches back
                0x7f, 0x08 => if (self.command.items.len > 0) {
                    _ = self.command.pop();
                },
                '\r', '\n' => return self.run(),
                else => if (byte >= 0x20) self.command.append(self.gpa, byte) catch {},
            },
            .escape => self.mode = .prompt,
            else => {},
        }
        return false;
    }

    fn run(self: *Editor) bool {
        const command = std.mem.trim(u8, self.command.items, " \t");
        self.mode = .prompt;
        if (eq(command, "q") or eq(command, "quit") or eq(command, "exit")) return true;
        if (eq(command, "prompt") or eq(command, "system")) {
            self.loadSystemPrompt() catch {
                self.status = "could not load the system prompt";
            };
        } else if (eq(command, "ipython") or eq(command, "python") or eq(command, "py")) {
            self.embed_requested = true;
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
        self.command.clearRetainingCapacity();
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

    // ── Editing, by grapheme ────────────────────────────────────────────────

    fn insertByte(self: *Editor, byte: u8) void {
        self.buffer.insert(self.gpa, self.cursor, byte) catch return;
        self.cursor += 1;
    }

    /// Removes the cluster before the cursor, or the newline joining the line
    /// above when the cursor is at a line start.
    fn backspace(self: *Editor) void {
        if (self.cursor == 0) return;
        const line = self.lineOf(self.cursor);
        const start = self.lineStart(line);
        const from = if (self.cursor == start) self.cursor - 1 else self.steppedBack(self.cursor);
        self.remove(from, self.cursor);
    }

    fn deleteCluster(self: *Editor) void {
        if (self.cursor >= self.buffer.items.len) return;
        self.remove(self.cursor, self.steppedForward(self.cursor));
    }

    /// Deletes `[from, to)` and leaves the cursor at `from`.
    fn remove(self: *Editor, from: usize, to: usize) void {
        if (to <= from) return;
        std.mem.copyForwards(u8, self.buffer.items[from..], self.buffer.items[to..]);
        self.buffer.items.len -= to - from;
        self.cursor = from;
    }

    fn steppedBack(self: *Editor, index: usize) usize {
        const line = self.lineOf(index);
        return kitty.prevGrapheme(self.buffer.items, self.lineStart(line), index);
    }

    fn steppedForward(self: *Editor, index: usize) usize {
        return kitty.nextGrapheme(self.buffer.items, index);
    }

    fn moveLine(self: *Editor, delta: isize) void {
        const line = self.lineOf(self.cursor);
        const target = @as(isize, @intCast(line)) + delta;
        if (target < 0 or target >= @as(isize, @intCast(self.lineCount()))) return;
        self.cursor = @min(self.lineStart(@intCast(target)) + self.cellsBefore(self.cursor), self.lineEnd(@intCast(target)));
    }

    // ── Lines, and where things sit on the screen ───────────────────────────

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

    /// The cells between a line's start and `index`.
    fn cellsBefore(self: *Editor, index: usize) usize {
        const start = self.lineStart(self.lineOf(index));
        return kitty.displayWidth(self.buffer.items[start..index]);
    }

    /// The columns a line takes, wrapped.
    fn lineRows(self: *Editor, line: usize) usize {
        const width = self.columns();
        const text = self.buffer.items[self.lineStart(line)..self.lineEnd(line)];
        var rows: usize = 1;
        var cells: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            const cells_here = kitty.clusterWidth(text, i);
            if (cells != 0 and cells + cells_here > width) {
                rows += 1;
                cells = 0;
            }
            cells += cells_here;
            i = kitty.nextGrapheme(text, i);
        }
        return rows;
    }

    /// The bytes of one wrapped row of a line.
    fn rowRange(self: *Editor, text: []const u8, target: usize) ?struct { start: usize, end: usize } {
        const width = self.columns();
        var row: usize = 0;
        var start: usize = 0;
        var cells: usize = 0;
        var i: usize = 0;
        while (true) {
            if (i >= text.len) {
                if (row == target) return .{ .start = start, .end = text.len };
                return null;
            }
            const cells_here = kitty.clusterWidth(text, i);
            if (cells != 0 and cells + cells_here > width) {
                if (row == target) return .{ .start = start, .end = i };
                row += 1;
                start = i;
                cells = 0;
            }
            cells += cells_here;
            i = kitty.nextGrapheme(text, i);
        }
    }

    fn columns(self: *Editor) usize {
        return if (self.cols > 1) self.cols else 1;
    }

    /// Where the cursor sits in display cells, with lines wrapped.
    fn cursorDisplay(self: *Editor) struct { row: usize, col: usize } {
        const cursor_line = self.lineOf(self.cursor);
        var row: usize = 0;
        var line: usize = 0;
        while (line < cursor_line) : (line += 1) row += self.lineRows(line);
        return .{ .row = row + self.cellsBefore(self.cursor) / self.columns(), .col = self.cellsBefore(self.cursor) % self.columns() };
    }

    // ── Drawing ─────────────────────────────────────────────────────────────

    fn render(self: *Editor) void {
        if (kitty.size()) |size| {
            self.rows = size.rows;
            self.cols = size.cols;
        }
        const height = if (self.rows > 3) self.rows - 2 else 1;
        const cursor = self.cursorDisplay();
        if (cursor.row < self.top) self.top = cursor.row;
        if (cursor.row >= self.top + height) self.top = cursor.row + 1 - height;

        kitty.write(kitty.erase_screen ++ kitty.cursor_home) catch {};
        kitty.print("\x1b[7m run1 \x1b[0m {s}  {d} lines  {s} \x1b[K", .{ @tagName(self.mode), self.lineCount(), self.status });

        var display: usize = 0;
        var drawn: usize = 0;
        var line: usize = 0;
        outer: while (line < self.lineCount()) : (line += 1) {
            const text = self.buffer.items[self.lineStart(line)..self.lineEnd(line)];
            var row: usize = 0;
            while (self.rowRange(text, row)) |range| : (row += 1) {
                if (display < self.top) {
                    display += 1;
                    continue;
                }
                if (drawn >= height) break :outer;
                kitty.print("\x1b[{d};1H\x1b[K", .{2 + drawn});
                kitty.write(text[range.start..range.end]) catch {};
                drawn += 1;
                display += 1;
            }
        }

        kitty.print("\x1b[{d};1H\x1b[K", .{self.rows});
        if (self.mode == .command) {
            kitty.print(":{s}", .{self.command.items});
            kitty.print("\x1b[{d};{d}H", .{ self.rows, self.command.items.len + 2 });
        } else {
            kitty.print("\x1b[{d};{d}H", .{ 2 + (cursor.row - self.top), cursor.col + 1 });
        }
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}