//! The TUI mode: a terminal editor with a multi-line prompt buffer and a
//! separate command buffer. Tab switches from the prompt to the command line;
//! on the command line Tab completes the word when there is one, and returns to
//! the prompt when the line is empty.
//!
//!   Tab              prompt → command; on the command line, complete, or leave
//!                    when it is empty
//!   :                also opens the command line
//!   Enter            a newline on the prompt; runs the command on the command line
//!   q, quit, exit    leave run1                    (a command)
//!   prompt, system   load the harness system prompt into the prompt buffer
//!   clear            empty the prompt buffer
//!   <ident>?         say what an identifier is — a command, or a feature of the
//!                    vocabulary and whether it is implemented
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

pub fn run(init: std.process.Init) !void {
    var editor: Editor = .{ .gpa = init.gpa };
    defer editor.deinit();
    if (init.environ_map.get("COLUMNS")) |value| editor.cols = std.fmt.parseInt(usize, value, 10) catch 80;
    if (init.environ_map.get("LINES")) |value| editor.rows = std.fmt.parseInt(usize, value, 10) catch 24;

    // No terminal to draw on: the caller falls back to the CLI.
    const raw = kitty.startRaw() catch return error.NotATerminal;
    defer raw.deinit();
    kitty.write(kitty.enter_alternate_screen) catch {};
    defer kitty.write(kitty.leave_alternate_screen ++ kitty.show_cursor) catch {};

    editor.render();
    while (true) {
        const key = kitty.readKey() catch break;
        if (try editor.handle(key)) break;
        editor.render();
    }
}

/// A command on the command line, and the line `name?` answers with.
const Command = struct { name: []const u8, help: []const u8 };

const commands = [_]Command{
    .{ .name = "q", .help = "command: leave run1" },
    .{ .name = "quit", .help = "command: leave run1" },
    .{ .name = "exit", .help = "command: leave run1" },
    .{ .name = "prompt", .help = "command: load the harness system prompt" },
    .{ .name = "system", .help = "command: load the harness system prompt" },
    .{ .name = "clear", .help = "command: empty the prompt buffer" },
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
    status_buffer: [192]u8 = undefined,
    cols: usize = 80,
    rows: usize = 24,
    /// The display row drawn on the editor's first row.
    top: usize = 0,

    const Mode = enum { prompt, command };

    fn deinit(self: *Editor) void {
        self.buffer.deinit(self.gpa);
        self.command.deinit(self.gpa);
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
                9 => if (self.command.items.len == 0) {
                    self.mode = .prompt;
                } else {
                    self.complete();
                },
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
        // Cleared after the command is used: `command` borrows that buffer.
        defer self.command.clearRetainingCapacity();
        self.mode = .prompt;

        // `ident?` — or `ident??` — asks what something is rather than doing it.
        if (std.mem.endsWith(u8, command, "?")) {
            self.describe(std.mem.trimEnd(u8, command, "?"));
            return false;
        }
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

    /// Says what `identifier` is: a command, or a feature of the vocabulary and
    /// whether the harness implements it.
    fn describe(self: *Editor, identifier: []const u8) void {
        if (identifier.len == 0) {
            self.status = "";
            return;
        }
        for (commands) |command| {
            if (eq(command.name, identifier)) {
                self.setStatus("{s} — {s}", .{ identifier, command.help });
                return;
            }
        }
        const omp = run1.omp_features;
        inline for (std.enums.values(omp.Kind)) |kind| {
            for (omp.table(kind)) |value| {
                if (eq(value, identifier)) {
                    self.setStatus("{s} — {s}, {s}", .{
                        identifier,
                        @tagName(kind),
                        if (omp.isImplemented(kind, value)) "implemented" else "not implemented",
                    });
                    return;
                }
            }
        }
        self.setStatus("{s} — nothing here goes by that name", .{identifier});
    }

    /// Replaces the word before the cursor with the next candidate it prefixes.
    fn complete(self: *Editor) void {
        const text = self.command.items;
        var start = text.len;
        while (start > 0 and text[start - 1] != ' ') start -= 1;
        const word = text[start..];
        const next = nextCompletion(word) orelse return;
        self.command.items.len = start;
        self.command.appendSlice(self.gpa, next) catch {};
    }

    fn loadSystemPrompt(self: *Editor) !void {
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try run1.system_prompt.systemPrompt(&out.writer);
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.gpa, out.written());
        self.cursor = 0;
        self.top = 0;
        self.setStatus("loaded the harness system prompt", .{});
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
            kitty.print("\x1b[{d};{d}H", .{ self.rows, self.command.items.len + 2 });
        } else {
            kitty.print("\x1b[{d};{d}H", .{ 2 + (cursor.row - self.top), cursor.col + 1 });
        }
    }
};

/// The next name `word` prefixes: a command first, then a feature of the
/// vocabulary. The first match, not a cycle — Tab completes rather than walks.
fn nextCompletion(word: []const u8) ?[]const u8 {
    if (word.len == 0) return null;
    for (commands) |command| {
        if (command.name.len > word.len and std.mem.startsWith(u8, command.name, word)) return command.name;
    }
    const omp = run1.omp_features;
    inline for (std.enums.values(omp.Kind)) |kind| {
        for (omp.table(kind)) |value| {
            if (value.len > word.len and std.mem.startsWith(u8, value, word)) return value;
        }
    }
    return null;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}