//! The TUI mode: a turn tree, drawn, with an IPython command line over it. The
//! turns are `editor.zig`'s tree — revisions, streams, merges, retroactive
//! edits — and this file is the modes, the keys, the command line and the
//! drawing.
//!
//! Keys are Kakoune's, and so is the model behind them: there is always a
//! selection, a motion moves the cursor and leaves the anchor — so the text
//! moved over is what is selected — and what `d`, `c` and typing act on is that
//! selection. `<esc>` leaves insert mode.
//!
//! Normal mode — the keys are commands:
//!   h j k l       left, down, up, right (the arrows do the same)
//!   w b e         word forward, back, and to the word's end
//!   i a I A       insert before, after, at the line's start, at its end
//!   o O           open a line below, above
//!   d c           delete the selection, or delete it and insert
//!   x % ;         the whole lines, the whole turn, collapse the selection
//!   u <a-u>       undo, redo — one run of typing undoes as one
//!   } {           select the next, previous turn: a retroactive edit's way in
//!   C             append an assistant turn by hand — what `/continue` was
//!   <a-b>         ask the prompt as a side question, on a revision of its own
//!   <a-t>         read the next revision: a view, nothing is written to it
//!   <a-m>         the tags the selected turn was generated with
//!   : Tab         the command line          Ctrl-C  leave run1
//!
//! Insert mode — the keys are text:
//!   Enter         send it: `!command` runs in fish, anything else the script's
//!                 `add_turn`, and a fresh prompt follows
//!   Shift-Enter   a newline, so a prompt can be several lines
//!   Esc           back to normal mode       Tab     the command line
//!
//! Command mode is IPython's: Enter runs the line in the shell, Tab completes,
//! Up and Down walk the shell's history, Ctrl-D comes back.
//!
//! Editing goes by grapheme, not by byte, and columns are counted in the cells
//! kitty draws. Long lines wrap. Every terminal call is `kitty.zig`, and the
//! shell is `ipython.zig`.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const kitty = @import("kitty.zig");
const ipython = @import("ipython.zig");
const editor = @import("editor.zig");
const row = @import("row.zig");
const theme = @import("theme.zig");
const screen = @import("screen.zig");

pub fn run(init: std.process.Init) !void {
    var tui = try Tui.init(init.gpa);
    defer tui.deinit();
    if (init.environ_map.get("COLUMNS")) |value| tui.cols = std.fmt.parseInt(usize, value, 10) catch 80;
    if (init.environ_map.get("LINES")) |value| tui.rows = std.fmt.parseInt(usize, value, 10) catch 24;

    // No terminal to draw on: the caller falls back to the CLI.
    const raw = kitty.startRaw() catch return error.NotATerminal;
    defer raw.deinit();
    kitty.write(kitty.enter_alternate_screen) catch {};
    kitty.write(kitty.push_keyboard_protocol) catch {};
    defer kitty.write(kitty.pop_keyboard_protocol ++ kitty.leave_alternate_screen ++ kitty.show_cursor) catch {};

    tui.render();
    while (true) {
        const key = kitty.readKey() catch break;
        if (try tui.handle(key)) break;
        tui.render();
    }
}

const Mode = enum { normal, insert, command };

const Tui = struct {
    gpa: std.mem.Allocator,
    doc: editor.Editor,
    /// The command line, kept apart from the prompt.
    command: std.ArrayList(u8) = .empty,
    command_cursor: usize = 0,
    /// The command line as it was before the history was walked, so Down can
    /// put it back.
    draft: std.ArrayList(u8) = .empty,
    history_offset: usize = 0,
    mode: Mode = .normal,
    status: []const u8 = "",
    status_buffer: [256]u8 = undefined,
    cols: usize = 80,
    rows: usize = 24,
    /// The display row drawn on the first row after the status.
    top: usize = 0,
    /// The frame being built, and the one last painted.
    frame: screen.Screen,

    fn init(gpa: std.mem.Allocator) !Tui {
        return .{ .gpa = gpa, .doc = try editor.Editor.init(gpa), .frame = screen.Screen.init(gpa) };
    }

    fn deinit(self: *Tui) void {
        self.doc.deinit();
        self.command.deinit(self.gpa);
        self.draft.deinit(self.gpa);
        self.frame.deinit();
    }

    fn setStatus(self: *Tui, comptime format: []const u8, args: anytype) void {
        self.status = std.fmt.bufPrint(&self.status_buffer, format, args) catch self.status_buffer[0..0];
    }

    fn handle(self: *Tui, key: kitty.Key) !bool {
        // A message is about the key that produced it, so the next key clears
        // it rather than leaving it to look like state.
        self.status = "";
        return switch (self.mode) {
            .normal => self.normalKey(key),
            .insert => self.insertKey(key),
            .command => self.commandKey(key),
        };
    }

    // ── Normal mode, as Kakoune's ───────────────────────────────────────────

    fn normalKey(self: *Tui, key: kitty.Key) bool {
        const text = self.doc.text();
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                9, ':' => self.mode = .command, // Tab, and `:` for a keyboard without one
                'h' => self.doc.stepTo(kitty.prevGrapheme(text, 0, self.doc.cursor)),
                'l' => self.doc.stepTo(kitty.nextGrapheme(text, self.doc.cursor)),
                'j' => self.moveLine(1),
                'k' => self.moveLine(-1),
                'w' => self.doc.stepTo(wordForward(text, self.doc.cursor)),
                'b' => self.doc.stepTo(wordBack(text, self.doc.cursor)),
                'e' => self.doc.stepTo(wordEnd(text, self.doc.cursor)),
                'i' => self.insertBefore(),
                'a' => self.insertAfter(),
                'I' => self.insertAt(self.doc.cursorLineStart()),
                'A' => self.insertAt(lineEnd(text, self.doc.cursorLineStart())),
                'o' => {
                    self.doc.record();
                    self.doc.openBelow();
                    self.mode = .insert;
                },
                'O' => {
                    self.doc.record();
                    self.doc.openAbove();
                    self.mode = .insert;
                },
                'd' => {
                    self.doc.record();
                    self.doc.deleteSelection();
                },
                'c' => {
                    self.doc.record();
                    self.doc.deleteSelection();
                    self.mode = .insert;
                },
                'u' => {
                    if (self.doc.undo()) {
                        self.setStatus("undone", .{});
                    } else {
                        self.setStatus("nothing to undo", .{});
                    }
                },
                'x' => self.doc.selectLines(),
                '%' => self.doc.selectAll(),
                ';' => self.doc.collapse(),
                '}' => {
                    self.doc.selectNext();
                    self.setStatus("{s} on {s}", .{ @tagName(self.doc.selectedKind()), self.doc.selectedRev() });
                },
                '{' => {
                    self.doc.selectPrevious();
                    self.setStatus("{s} on {s}", .{ @tagName(self.doc.selectedKind()), self.doc.selectedRev() });
                },
                'C' => {
                    // By hand: another assistant turn, which `/continue` was,
                    // with a fresh prompt after it.
                    _ = self.doc.appendAssistantTurn() catch {};
                    _ = self.doc.newPrompt() catch {};
                    self.setStatus("assistant turn appended", .{});
                },
                else => {},
            },
            .alt => |letter| switch (letter) {
                'b' => self.askSide(),
                't' => self.readNext(),
                'm' => self.showTags(),
                'u' => {
                    if (self.doc.redo()) {
                        self.setStatus("redone", .{});
                    } else {
                        self.setStatus("nothing to redo", .{});
                    }
                },
                else => {},
            },
            .escape => self.doc.collapse(),
            .left => self.doc.stepTo(kitty.prevGrapheme(text, 0, self.doc.cursor)),
            .right => self.doc.stepTo(kitty.nextGrapheme(text, self.doc.cursor)),
            .up => self.moveLine(-1),
            .down => self.moveLine(1),
            .home => self.doc.stepTo(self.doc.cursorLineStart()),
            .end => self.doc.stepTo(lineEnd(text, self.doc.cursorLineStart())),
            .delete => self.doc.deleteSelection(),
            .shift_enter, .eof, .unknown => {},
        }
        return false;
    }

    /// `i`: insert at the selection's start, keeping the selection so that
    /// typing replaces it.
    fn insertBefore(self: *Tui) void {
        self.doc.record();
        const range = self.doc.selection();
        self.doc.moveCursor(range.start);
        self.doc.anchor = range.end;
        self.mode = .insert;
    }

    /// `a`: the same, past the selection's end.
    fn insertAfter(self: *Tui) void {
        self.doc.record();
        const range = self.doc.selection();
        self.doc.moveCursor(range.end);
        self.doc.anchor = range.start;
        self.mode = .insert;
    }

    fn insertAt(self: *Tui, index: usize) void {
        self.doc.record();
        self.doc.moveCursor(index);
        self.mode = .insert;
    }

    // ── Insert mode ─────────────────────────────────────────────────────────

    fn insertKey(self: *Tui, key: kitty.Key) bool {
        const text = self.doc.text();
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                9 => self.mode = .command, // Tab
                '\r', '\n' => self.submit(),
                0x7f, 0x08 => self.backspace(),
                else => if (byte >= 0x20) self.typeByte(byte),
            },
            .alt => |letter| switch (letter) {
                'b' => self.askSide(),
                't' => self.readNext(),
                'm' => self.showTags(),
                else => {},
            },
            .shift_enter => self.typeByte('\n'),
            .left => self.doc.moveCursor(kitty.prevGrapheme(text, self.doc.cursorLineStart(), self.doc.cursor)),
            .right => self.doc.moveCursor(kitty.nextGrapheme(text, self.doc.cursor)),
            .up => self.moveLine(-1),
            .down => self.moveLine(1),
            .home => self.doc.moveCursor(self.doc.cursorLineStart()),
            .end => self.doc.moveCursor(lineEnd(text, self.doc.cursorLineStart())),
            .delete => self.doc.remove(self.doc.cursor, kitty.nextGrapheme(text, self.doc.cursor)),
            .escape => {
                self.mode = .normal;
                self.doc.collapse();
            },
            .eof, .unknown => {},
        }
        return false;
    }

    /// Types a byte in insert mode. Kakoune's rule: typing replaces the
    /// selection, so a non-empty one goes first.
    fn typeByte(self: *Tui, byte: u8) void {
        const range = self.doc.selection();
        if (range.end > range.start) self.doc.deleteSelection();
        self.doc.insertByte(byte);
        self.doc.collapse();
    }

    /// Sends the prompt. A line starting with `!` runs in fish; anything else
    /// goes through the scripting layer's `add_turn`. Either way the turn leaves
    /// the prompt, the reply streams from it onto the revision, and a fresh
    /// prompt follows.
    fn submit(self: *Tui) void {
        const text = self.doc.text();
        if (text.len == 0) {
            self.status = "nothing to send";
            return;
        }
        self.status = "";
        const sent = self.gpa.dupe(u8, text) catch return;
        defer self.gpa.free(sent);
        const bang = std.mem.startsWith(u8, sent, "!");

        const output = (if (bang)
            ipython.fish(self.gpa, std.mem.trimStart(u8, sent[1..], " \t"))
        else
            ipython.addTurn(self.gpa, sent)) catch {
            self.status = "the scripting layer failed";
            return;
        };
        defer self.gpa.free(output);

        _ = self.doc.markSent();
        if (self.stream(output)) |stream_handle| {
            // What made this turn, as far as this side knows. The model id and
            // the effort come from whoever runs the model; the script is what
            // answered here.
            self.doc.tag(stream_handle, "source", if (bang) "fish" else "add_turn") catch {};
            self.doc.merge(stream_handle) catch {};
        }
        _ = self.doc.newPrompt() catch {};
    }

    /// Streams a reply in line by line, the way a model's answer arrives, and
    /// returns its handle. The caller decides whether it joins the revision.
    fn stream(self: *Tui, output: []const u8) ?editor.Stream {
        if (output.len == 0) return null;
        const stream_handle = self.doc.beginAssistant() catch return null;
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |piece| {
            if (piece.len == 0 and lines.rest().len == 0) break; // the trailing newline
            self.doc.appendAssistant(stream_handle, piece) catch break;
            self.doc.appendAssistant(stream_handle, "\n") catch break;
        }
        return stream_handle;
    }

    fn backspace(self: *Tui) void {
        if (self.doc.cursor == 0) return;
        const text = self.doc.text();
        const start = self.doc.cursorLineStart();
        const from = if (self.doc.cursor == start) self.doc.cursor - 1 else kitty.prevGrapheme(text, start, self.doc.cursor);
        self.doc.remove(from, self.doc.cursor);
    }

    fn moveLine(self: *Tui, delta: isize) void {
        const text = self.doc.text();
        const start = self.doc.cursorLineStart();
        const cells = kitty.displayWidth(text[start..self.doc.cursor]);
        var line_start = start;
        var line_end = lineEnd(text, start);
        if (delta < 0) {
            if (start == 0) return;
            line_end = start - 1;
            line_start = lineStart(text, line_end);
        } else {
            if (line_end >= text.len) return;
            line_start = line_end + 1;
            line_end = lineEnd(text, line_start);
        }
        self.doc.moveCursor(cellAt(text[line_start..line_end], cells) + line_start);
    }

    // ── The editor's own commands, as keys ──────────────────────────────────

    /// `<a-b>`: the prompt's text becomes a side question on a revision of its
    /// own, with an assistant turn already open for the answer. The revision
    /// being typed into is left alone.
    fn askSide(self: *Tui) void {
        const question = self.doc.text();
        if (question.len == 0) {
            self.status = "nothing to ask";
            return;
        }
        _ = self.doc.beginBtw(question) catch {
            self.status = "could not open a side question";
            return;
        };
        self.doc.remove(0, question.len);
        self.setStatus("side question: {s}", .{self.doc.revNameAt(self.doc.revCount() - 1)});
    }

    /// `<a-t>`: read the next revision — a view. Nothing is written to what is
    /// read, and after the last one the view returns to the revision being
    /// typed into.
    fn readNext(self: *Tui) void {
        const count = self.doc.revCount();
        const next: usize = if (self.doc.reading) |reading| reading + 1 else 0;
        if (next >= count) {
            self.doc.stopReading();
            self.setStatus("back at {s}", .{self.doc.revName()});
            return;
        }
        _ = self.doc.readRev(next);
        self.setStatus("reading {s}", .{self.doc.revNameAt(next)});
    }

    /// `<a-m>`: the tags on the selected turn — the model, the thinking effort
    /// and whatever else it was generated with.
    fn showTags(self: *Tui) void {
        const tags = self.doc.tagsOf(self.doc.selected);
        if (tags.len == 0) {
            self.setStatus("{s}: no tags", .{@tagName(self.doc.selectedKind())});
            return;
        }
        var length: usize = 0;
        for (tags, 0..) |tag, i| {
            const parts = [_][]const u8{ if (i == 0) "" else " ", tag.key, "=", tag.value };
            for (parts) |part| {
                for (part) |byte| {
                    if (length >= self.status_buffer.len) break;
                    self.status_buffer[length] = byte;
                    length += 1;
                }
            }
        }
        self.status = self.status_buffer[0..length];
    }

    // ── Command mode, as IPython's ──────────────────────────────────────────

    fn commandKey(self: *Tui, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                4 => self.mode = .normal, // Ctrl-D, back to the tree
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
            .escape => self.mode = .normal,
            .alt, .shift_enter, .eof, .unknown => {},
        }
        return false;
    }

    fn runCommand(self: *Tui) bool {
        const line = std.mem.trim(u8, self.command.items, " \t");
        defer {
            self.command.clearRetainingCapacity();
            self.command_cursor = 0;
            self.history_offset = 0;
        }
        self.mode = .normal;
        if (line.len == 0) {
            self.status = "";
            return false;
        }
        const output = ipython.run(self.gpa, line) catch {
            self.status = "the scripting layer failed";
            return false;
        };
        defer self.gpa.free(output);
        if (output.len != 0) _ = self.doc.add(.output, output) catch {};
        self.setStatus("{s}", .{std.mem.sliceTo(output, '\n')});
        return false;
    }

    /// Completes the word before the cursor from the shell, and lists what it
    /// found on the status row.
    fn complete(self: *Tui) void {
        const line = self.command.items;
        const output = ipython.complete(self.gpa, line, self.command_cursor) catch return;
        defer self.gpa.free(output);
        if (output.len == 0) return;

        var matches = std.mem.splitScalar(u8, output, '\n');
        const first = matches.next() orelse return;

        var start = self.command_cursor;
        while (start > 0 and isWordByte(line[start - 1])) start -= 1;
        const tail = self.gpa.dupe(u8, line[self.command_cursor..]) catch return;
        defer self.gpa.free(tail);
        self.command.items.len = start;
        self.command.appendSlice(self.gpa, first) catch return;
        self.command.appendSlice(self.gpa, tail) catch return;
        self.command_cursor = start + first.len;

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
    fn history(self: *Tui, delta: isize) void {
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

    fn setCommand(self: *Tui, text: []const u8) void {
        self.command.clearRetainingCapacity();
        self.command.appendSlice(self.gpa, text) catch {};
        self.command_cursor = self.command.items.len;
    }

    fn commandInsert(self: *Tui, byte: u8) void {
        self.command.insert(self.gpa, self.command_cursor, byte) catch return;
        self.command_cursor += 1;
    }

    fn commandBackspace(self: *Tui) void {
        if (self.command_cursor == 0) return;
        _ = self.command.orderedRemove(self.command_cursor - 1);
        self.command_cursor -= 1;
    }

    // ── Drawing ─────────────────────────────────────────────────────────────

    fn columns(self: *Tui) usize {
        return if (self.cols > 1) self.cols else 1;
    }

    fn render(self: *Tui) void {
        if (kitty.size()) |size| {
            self.rows = size.rows;
            self.cols = size.cols;
        }
        const width = self.columns();
        const height = if (self.rows > 2) self.rows - 2 else 1;
        self.frame.height = self.rows;

        var transcript: std.ArrayList([]u8) = .empty;
        defer freeRows(self.gpa, &transcript);
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;
        self.turnRows(&transcript, width, &cursor_row, &cursor_col) catch {};

        // Keep the cursor in view.
        if (cursor_row < self.top) self.top = cursor_row;
        if (cursor_row >= self.top + height) self.top = cursor_row + 1 - height;
        if (transcript.items.len >= height and self.top + height > transcript.items.len) {
            self.top = transcript.items.len - height;
        }
        if (self.top > transcript.items.len) self.top = transcript.items.len;

        self.frame.clear();
        self.statusRow(width) catch {};
        var drawn: usize = 0;
        while (drawn < height) : (drawn += 1) {
            const index = self.top + drawn;
            if (index >= transcript.items.len) break;
            self.frame.add(transcript.items[index]) catch {};
        }

        if (self.mode == .command) {
            self.commandRow(width) catch {};
            self.frame.place(self.rows - 1, @min(self.command_cursor + 2, width - 1));
        } else {
            self.frame.place(1 + (cursor_row - self.top), @min(cursor_col, width - 1));
        }
        self.frame.flush();
    }

    /// The bar: the mode, the revision, the turn being edited, and whatever the
    /// last key had to say.
    fn statusRow(self: *Tui, width: usize) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.appendSlice(self.gpa, " run1  ");
        try text.appendSlice(self.gpa, @tagName(self.mode));
        try text.appendSlice(self.gpa, "  rev ");
        try text.appendSlice(self.gpa, self.doc.revName());
        try text.appendSlice(self.gpa, "  sel ");
        try text.appendSlice(self.gpa, @tagName(self.doc.selectedKind()));
        if (self.doc.readingName()) |name| {
            try text.appendSlice(self.gpa, "  reading ");
            try text.appendSlice(self.gpa, name);
        }
        if (self.doc.streamCount() != 0) {
            var count: [32]u8 = undefined;
            try text.appendSlice(self.gpa, try std.fmt.bufPrint(&count, "  {d} streaming", .{self.doc.streamCount()}));
        }
        if (self.status.len != 0) {
            try text.appendSlice(self.gpa, "  — ");
            try text.appendSlice(self.gpa, self.status);
        }

        const kept = try row.truncate(self.gpa, text.items, width);
        defer self.gpa.free(kept);
        var padded: std.ArrayList(u8) = .empty;
        defer padded.deinit(self.gpa);
        try padded.appendSlice(self.gpa, kept);
        const cells = row.visibleWidth(kept);
        if (cells < width) try padded.appendNTimes(self.gpa, ' ', width - cells);
        const painted = try theme.paint(self.gpa, theme.bar, padded.items);
        defer self.gpa.free(painted);
        try self.frame.add(painted);
    }

    /// The command line, on the last row.
    fn commandRow(self: *Tui, width: usize) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.appendSlice(self.gpa, ": ");
        try text.appendSlice(self.gpa, self.command.items);
        const kept = try row.truncate(self.gpa, text.items, width);
        defer self.gpa.free(kept);
        try self.frame.add(kept);
    }

    /// The turns, each with its gutter, wrapped to the width — and where the
    /// cursor lands among the rows they made.
    fn turnRows(self: *Tui, out: *std.ArrayList([]u8), width: usize, cursor_row: *usize, cursor_col: *usize) !void {
        var turns: std.ArrayList(editor.Turn) = .empty;
        defer turns.deinit(self.gpa);
        try self.doc.view(&turns);

        const gutter = 2;
        const inner = if (width > gutter) width - gutter else 1;
        const range = self.doc.selection();

        for (turns.items) |turn| {
            const raw = self.doc.turnText(turn);
            const styled = if (turn == self.doc.selected)
                try theme.highlight(self.gpa, raw, range.start, range.end)
            else
                try self.gpa.dupe(u8, raw);
            defer self.gpa.free(styled);

            var wrapped: std.ArrayList([]u8) = .empty;
            defer freeRows(self.gpa, &wrapped);
            try row.wrap(self.gpa, styled, inner, &wrapped);

            const first = gutterFor(self.doc.turnKind(turn));
            for (wrapped.items, 0..) |text, i| {
                const line = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ if (i == 0) first else "  ", text });
                errdefer self.gpa.free(line);
                try out.append(self.gpa, line);
            }
            if (turn == self.doc.selected and wrapped.items.len != 0) {
                const position = wrappedPosition(raw, self.doc.cursor, inner);
                if (position.row < wrapped.items.len) {
                    cursor_row.* = out.items.len - (wrapped.items.len - position.row);
                    cursor_col.* = gutter + position.col;
                }
            }
        }
    }
};

/// The two cells before a turn: a mark for what it is, and the space after it.
fn gutterFor(kind: editor.Kind) []const u8 {
    return switch (kind) {
        .prompt => theme.accent ++ "›" ++ theme.reset ++ " ",
        .user => theme.bold ++ "›" ++ theme.reset ++ " ",
        .assistant => "∙ ",
        .output => theme.dim ++ "∙" ++ theme.reset ++ " ",
    };
}

/// Where the cursor sits once `text` is wrapped: which row of it, and which
/// cell in that row.
fn wrappedPosition(text: []const u8, index: usize, width: usize) struct { row: usize, col: usize } {
    var at: usize = 0;
    var at_row: usize = 0;
    var cells: usize = 0;
    const limit = @min(index, text.len);
    while (at < limit) {
        const here = kitty.clusterWidth(text, at);
        if (cells != 0 and cells + here > width) {
            at_row += 1;
            cells = 0;
        }
        cells += here;
        at = kitty.nextGrapheme(text, at);
    }
    return .{ .row = at_row, .col = cells };
}

/// Frees the rows of a list this file built.
fn freeRows(gpa: std.mem.Allocator, rows: *std.ArrayList([]u8)) void {
    for (rows.items) |text| gpa.free(text);
    rows.clearRetainingCapacity();
}

/// Whether a byte is part of a word, for the word motions.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// `w`: past this word, then past the whitespace, to the next word's start.
fn wordForward(text: []const u8, index: usize) usize {
    var at = index;
    if (at < text.len) at = kitty.nextGrapheme(text, at);
    while (at < text.len and isWordByte(text[at])) at = kitty.nextGrapheme(text, at);
    while (at < text.len and !isWordByte(text[at]) and text[at] != '\n') at = kitty.nextGrapheme(text, at);
    return at;
}

/// `b`: back over the whitespace, then to this word's start.
fn wordBack(text: []const u8, index: usize) usize {
    var at = index;
    while (at > 0) {
        const previous = kitty.prevGrapheme(text, 0, at);
        if (isWordByte(text[previous])) break;
        at = previous;
    }
    while (at > 0) {
        const previous = kitty.prevGrapheme(text, 0, at);
        if (!isWordByte(text[previous])) break;
        at = previous;
    }
    return at;
}

/// `e`: past the whitespace, then to the end of the word there.
fn wordEnd(text: []const u8, index: usize) usize {
    var at = index;
    while (at < text.len and !isWordByte(text[at])) at = kitty.nextGrapheme(text, at);
    while (at < text.len and isWordByte(text[at])) at = kitty.nextGrapheme(text, at);
    return at;
}

/// The byte index where the line starting at `start` ends.
fn lineEnd(text: []const u8, start: usize) usize {
    if (std.mem.indexOfScalar(u8, text[start..], '\n')) |offset| return start + offset;
    return text.len;
}

/// The byte index where the line containing `index` starts.
fn lineStart(text: []const u8, index: usize) usize {
    return (std.mem.lastIndexOfScalar(u8, text[0..index], '\n') orelse return 0) + 1;
}

/// The byte index in `text` whose display cells reach `cells`, staying inside
/// the line.
fn cellAt(text: []const u8, cells: usize) usize {
    var at: usize = 0;
    var seen: usize = 0;
    while (at < text.len) {
        const here = kitty.clusterWidth(text, at);
        if (seen + here > cells) break;
        seen += here;
        at = kitty.nextGrapheme(text, at);
    }
    return at;
}
