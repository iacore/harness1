//! The TUI mode: a prompt buffer and, over it, an IPython command line.
//!
//! Normal mode, on the prompt:
//!   Enter          send it — `!command` runs it in fish, anything else the
//!                  script's `add_turn` — and clear the buffer
//!   Shift-Enter    a newline, so a prompt can be several lines
//!   Tab, `:`       the command line
//!   Ctrl-C         leave run1
//!
//! Command mode, on the command line, behaves as IPython's does:
//!   Enter          run the line in the shell and show what it prints
//!   Tab            complete the word at the cursor
//!   Up, Down       the shell's history
//!   Ctrl-D         back to the prompt
//!   Ctrl-C         leave run1
//!
//! Editing goes by grapheme, not by byte: Backspace and Delete remove a whole
//! cluster, the arrows step one, Home and End go to the line's ends, and
//! columns are counted in the cells kitty draws — so a combining mark stays
//! with its base and a wide character takes two columns. Long lines wrap. Every
//! terminal call is `kitty.zig`, and the shell is `ipython.zig`.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const kitty = @import("kitty.zig");
const ipython = @import("ipython.zig");

pub fn run(init: std.process.Init) !void {
    var editor: Editor = .{ .gpa = init.gpa };
    defer editor.deinit();
    if (init.environ_map.get("COLUMNS")) |value| editor.cols = std.fmt.parseInt(usize, value, 10) catch 80;
    if (init.environ_map.get("LINES")) |value| editor.rows = std.fmt.parseInt(usize, value, 10) catch 24;

    // No terminal to draw on: the caller falls back to the CLI.
    const raw = kitty.startRaw() catch return error.NotATerminal;
    defer raw.deinit();
    kitty.write(kitty.enter_alternate_screen) catch {};
    kitty.write(kitty.push_keyboard_protocol) catch {};
    defer kitty.write(kitty.pop_keyboard_protocol ++ kitty.leave_alternate_screen ++ kitty.show_cursor) catch {};

    editor.render();
    while (true) {
        const key = kitty.readKey() catch break;
        if (try editor.handle(key)) break;
        editor.render();
    }
}

const Editor = struct {
    gpa: std.mem.Allocator,
    /// The prompt being edited.
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    /// The command line, kept apart from the prompt.
    command: std.ArrayList(u8) = .empty,
    command_cursor: usize = 0,
    /// The line as it was before the history was walked, so Down can put it back.
    draft: std.ArrayList(u8) = .empty,
    history_offset: usize = 0,
    mode: Mode = .prompt,
    status: []const u8 = "",
    status_buffer: [192]u8 = undefined,
    cols: usize = 80,
    rows: usize = 24,
    /// The display row drawn on the editor's first row.
    top: usize = 0,

    const Mode = enum { prompt, command };

    fn deinit(self: *Editor) void {
        self.buffer.deinit(self.gpa);
        self.command.deinit(self.gpa);
        self.draft.deinit(self.gpa);
    }

    fn setStatus(self: *Editor, comptime format: []const u8, args: anytype) void {
        self.status = std.fmt.bufPrint(&self.status_buffer, format, args) catch self.status_buffer[0..0];
    }

    fn handle(self: *Editor, key: kitty.Key) !bool {
        return switch (self.mode) {
            .prompt => self.promptKey(key),
            .command => self.commandKey(key),
        };
    }

    // ── Normal mode ─────────────────────────────────────────────────────────

    fn promptKey(self: *Editor, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                9, ':' => self.mode = .command, // Tab, and `:` for a keyboard without one
                '\r', '\n' => self.submit(),
                0x7f, 0x08 => self.backspace(),
                else => if (byte >= 0x20) self.insertByte(byte),
            },
            .shift_enter => self.insertByte('\n'),
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

    /// Sends the prompt. A line starting with `!` runs in fish — the shell set
    /// up for this — and anything else goes through the scripting layer's
    /// `add_turn`, so sending a turn is a step like any other.
    fn submit(self: *Editor) void {
        if (self.buffer.items.len == 0) {
            self.status = "nothing to send";
            return;
        }
        const bang = std.mem.startsWith(u8, self.buffer.items, "!");
        const output = (if (bang)
            ipython.fish(self.gpa, std.mem.trimStart(u8, self.buffer.items[1..], " \t"))
        else
            ipython.addTurn(self.gpa, self.buffer.items)) catch {
            self.status = "the scripting layer failed";
            return;
        };
        defer self.gpa.free(output);
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.top = 0;
        self.show(output);
    }

    // ── Command mode, as IPython's ──────────────────────────────────────────

    fn commandKey(self: *Editor, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                4 => self.mode = .prompt, // Ctrl-D, back to the prompt
                9 => self.complete(),
                '\r', '\n' => return self.runCommand(),
                0x7f, 0x08 => self.commandBackspace(),
                else => if (byte >= 0x20) self.commandInsert(byte),
            },
            .left => if (self.command_cursor > 0) {
                self.command_cursor -= 1;
            },
            .right => if (self.command_cursor < self.command.items.len) {
                self.command_cursor += 1;
            },
            .up => self.history(1),
            .down => self.history(-1),
            .home => self.command_cursor = 0,
            .end => self.command_cursor = self.command.items.len,
            .delete => if (self.command_cursor < self.command.items.len) {
                _ = self.command.orderedRemove(self.command_cursor);
            },
            .escape => self.mode = .prompt,
            .shift_enter, .eof, .unknown => {},
        }
        return false;
    }

    fn runCommand(self: *Editor) bool {
        const line = std.mem.trim(u8, self.command.items, " \t");
        defer {
            self.command.clearRetainingCapacity();
            self.command_cursor = 0;
            self.history_offset = 0;
        }
        self.mode = .prompt;
        if (line.len == 0) {
            self.status = "";
            return false;
        }
        const output = ipython.run(self.gpa, line) catch {
            self.status = "the scripting layer failed";
            return false;
        };
        defer self.gpa.free(output);
        self.show(output);
        return false;
    }

    /// Completes the word before the cursor from the shell, and lists what it
    /// found on the status row.
    fn complete(self: *Editor) void {
        const line = self.command.items;
        const output = ipython.complete(self.gpa, line, self.command_cursor) catch return;
        defer self.gpa.free(output);
        if (output.len == 0) return;

        var matches = std.mem.splitScalar(u8, output, '\n');
        const first = matches.next() orelse return;

        // Replace the word before the cursor, keeping whatever follows it.
        var start = self.command_cursor;
        while (start > 0 and isWordByte(line[start - 1])) start -= 1;
        const tail = self.gpa.dupe(u8, line[self.command_cursor..]) catch return;
        defer self.gpa.free(tail);
        self.command.items.len = start;
        self.command.appendSlice(self.gpa, first) catch return;
        self.command.appendSlice(self.gpa, tail) catch return;
        self.command_cursor = start + first.len;

        // The matches on the status row, one line turned into spaces.
        var length: usize = 0;
        for (output) |byte| {
            if (length >= self.status_buffer.len) break;
            self.status_buffer[length] = if (byte == '\n') ' ' else byte;
            length += 1;
        }
        self.status = self.status_buffer[0..length];
    }

    /// Walks the shell's history: up goes back, down comes forward, and coming
    /// back to the start restores the line that was being typed.
    fn history(self: *Editor, delta: isize) void {
        const next = @as(isize, @intCast(self.history_offset)) + delta;
        if (next < 0) return;
        if (next == 0) {
            if (self.history_offset != 0) self.setCommand(self.draft.items);
            self.history_offset = 0;
            return;
        }
        if (self.history_offset == 0) {
            self.draft.clearRetainingCapacity();
            self.draft.appendSlice(self.gpa, self.command.items) catch {};
        }
        const entry = ipython.history(self.gpa, @intCast(next)) catch return;
        defer self.gpa.free(entry);
        if (entry.len == 0) return;
        self.setCommand(entry);
        self.history_offset = @intCast(next);
    }

    fn setCommand(self: *Editor, text: []const u8) void {
        self.command.clearRetainingCapacity();
        self.command.appendSlice(self.gpa, text) catch {};
        self.command_cursor = self.command.items.len;
    }

    fn commandInsert(self: *Editor, byte: u8) void {
        self.command.insert(self.gpa, self.command_cursor, byte) catch return;
        self.command_cursor += 1;
    }

    fn commandBackspace(self: *Editor) void {
        if (self.command_cursor == 0) return;
        _ = self.command.orderedRemove(self.command_cursor - 1);
        self.command_cursor -= 1;
    }

    /// Puts what the shell printed after the prompt, and its first line on the
    /// status row.
    fn show(self: *Editor, output: []const u8) void {
        if (output.len == 0) {
            self.status = "";
            return;
        }
        self.buffer.appendSlice(self.gpa, output) catch return;
        self.cursor = self.buffer.items.len;
        self.setStatus("{s}", .{std.mem.sliceTo(output, '\n')});
    }

    // ── Editing the prompt, by grapheme ─────────────────────────────────────

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
            const here = kitty.clusterWidth(text, i);
            if (cells != 0 and cells + here > width) {
                rows += 1;
                cells = 0;
            }
            cells += here;
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
            const here = kitty.clusterWidth(text, i);
            if (cells != 0 and cells + here > width) {
                if (row == target) return .{ .start = start, .end = i };
                row += 1;
                start = i;
                cells = 0;
            }
            cells += here;
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
        const cells = self.cellsBefore(self.cursor);
        return .{ .row = row + cells / self.columns(), .col = cells % self.columns() };
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
            kitty.print("\x1b[{d};{d}H", .{ self.rows, self.command_cursor + 2 });
        } else {
            kitty.print("\x1b[{d};{d}H", .{ 2 + (cursor.row - self.top), cursor.col + 1 });
        }
    }
};

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_';
}