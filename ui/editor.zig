//! The turns, as a tree rather than one buffer: every turn is a node naming the
//! turn it answers, and a *revision* — a `rev` — is a name plus the turn that
//! revision is at. The prompt is the head of the current rev, so what is being
//! typed is always the deepest turn on the rev you are on.
//!
//! Three things follow from the shape rather than from a mode:
//!
//! *Several turns streaming at once.* `beginAssistant` opens a stream on a rev
//! of its own, off the turn the reply answers, and returns a handle; each open
//! stream is drawn after the current rev. This is what a `/btw` or a `/tan` used
//! to be: a second turn in flight, not a mode.
//!
//! *Merging.* `merge` moves an open stream onto the current rev as its next
//! turn. The rev keeps its name — merging adds a turn, it does not rename
//! anything.
//!
//! *Retroactive editing.* `select` points the cursor at any turn, not only the
//! head, and the editing calls write there. The turns after it stay where they
//! are, because they are its children rather than the tail of a list: editing a
//! turn changes what that turn says, not where anything sits.
//!
//! Drawing is not this file's business. It offers lines and the cursor's place
//! among them (`lineCount`, `line`, `cursorLine`, `cursorColumn`), and `tui.zig`
//! draws them.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    /// An editable prompt turn.
    prompt,
    /// A turn the prompt sent.
    user,
    /// A turn an assistant produced, streamed in.
    assistant,
    /// What a command printed.
    output,
};

/// A fact about how a turn was made: the model id, the thinking effort, and
/// whatever else the caller knows. Keys are free rather than an enum, because
/// the set follows the API's, not this file's.
pub const Tag = struct { key: []const u8, value: []const u8 };

pub const Node = struct {
    kind: Kind,
    text: std.ArrayList(u8) = .empty,
    /// The turn this one answers, or null for the root.
    parent: ?usize = null,
    /// The revision this turn belongs to.
    rev: usize = 0,
    /// How this turn was generated. The keys in use are `model`, `thinking`,
    /// `provider` and `source`; an assistant turn carries what its generator
    /// knew, and an empty value is left rather than guessed at.
    tags: std.ArrayList(Tag) = .empty,
};

/// A revision of the tree: a name, and the turn that revision is at.
pub const Rev = struct {
    /// Stable for the revision's life. Retroactive edits do not rename it.
    name: []u8,
    /// The turn the revision is at.
    head: Turn,
};

/// A turn's index, stable: nodes are never removed, so a handle stays good.
pub const Turn = usize;
pub const Stream = Turn;

pub const Editor = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    revs: std.ArrayList(Rev) = .empty,
    current: usize = 0,
    /// The turn the cursor edits.
    selected: Turn = 0,
    /// Byte index into the selected turn's text.
    cursor: usize = 0,
    /// The other end of the selection. Equal to the cursor when nothing is
    /// selected, and a motion moves the cursor while the anchor stays, so the
    /// moved-over text is what is selected.
    anchor: usize = 0,
    /// Reading a revision, when one is. Reading is a view: the revision that was
    /// forked off receives nothing, and what is typed still goes to `current`.
    reading: ?usize = null,
    /// Streams still open.
    open: std.ArrayList(Stream) = .empty,
    /// What the turns said before the changes, newest last.
    undo_stack: std.ArrayList(Change) = .empty,
    redo_stack: std.ArrayList(Change) = .empty,

    /// One turn's text, as it was at a point in time.
    const Change = struct {
        turn: Turn,
        text: []u8,
        cursor: usize,
        anchor: usize,
    };

    pub fn init(gpa: Allocator) !Editor {
        var editor: Editor = .{ .gpa = gpa };
        errdefer editor.deinit();
        try editor.nodes.append(gpa, .{ .kind = .prompt, .rev = 0 });
        try editor.revs.append(gpa, .{ .name = try gpa.dupe(u8, "main"), .head = 0 });
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        for (self.nodes.items) |*node| {
            node.text.deinit(self.gpa);
            for (node.tags.items) |entry| {
                self.gpa.free(entry.key);
                self.gpa.free(entry.value);
            }
            node.tags.deinit(self.gpa);
        }
        self.nodes.deinit(self.gpa);
        for (self.revs.items) |rev| self.gpa.free(rev.name);
        self.revs.deinit(self.gpa);
        self.open.deinit(self.gpa);
        for (self.undo_stack.items) |change| self.gpa.free(change.text);
        self.undo_stack.deinit(self.gpa);
        for (self.redo_stack.items) |change| self.gpa.free(change.text);
        self.redo_stack.deinit(self.gpa);
    }

    /// Tags a turn with one fact about how it was made. An empty value is not
    /// recorded: a tag that says nothing is worse than the tag being absent.
    pub fn tag(self: *Editor, turn: Turn, key: []const u8, value: []const u8) !void {
        if (turn >= self.nodes.items.len or value.len == 0) return;
        const node = &self.nodes.items[turn];
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        const owned_value = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(owned_value);
        try node.tags.append(self.gpa, .{ .key = owned_key, .value = owned_value });
    }

    pub fn tagsOf(self: *Editor, turn: Turn) []const Tag {
        if (turn >= self.nodes.items.len) return &.{};
        return self.nodes.items[turn].tags.items;
    }

    // ── Undo ────────────────────────────────────────────────────────────────

    /// Notes what the edited turn says now, before a change is made to it. A
    /// caller records once per action — entering insert mode, or a delete — so
    /// a run of typing undoes as one, the way Kakoune groups it.
    pub fn record(self: *Editor) void {
        const node = &self.nodes.items[self.selected];
        const copy = self.gpa.dupe(u8, node.text.items) catch return;
        self.undo_stack.append(self.gpa, .{
            .turn = self.selected,
            .text = copy,
            .cursor = self.cursor,
            .anchor = self.anchor,
        }) catch {
            self.gpa.free(copy);
            return;
        };
        for (self.redo_stack.items) |change| self.gpa.free(change.text);
        self.redo_stack.clearRetainingCapacity();
    }

    pub fn undo(self: *Editor) bool {
        const change = self.undo_stack.pop() orelse return false;
        self.swap(change, &self.redo_stack);
        return true;
    }

    pub fn redo(self: *Editor) bool {
        const change = self.redo_stack.pop() orelse return false;
        self.swap(change, &self.undo_stack);
        return true;
    }

    /// Puts `change`'s text back, and remembers what is there now on `keep`.
    fn swap(self: *Editor, change: Change, keep: *std.ArrayList(Change)) void {
        const node = &self.nodes.items[change.turn];
        const current = self.gpa.dupe(u8, node.text.items) catch {
            self.gpa.free(change.text);
            return;
        };
        keep.append(self.gpa, .{
            .turn = change.turn,
            .text = current,
            .cursor = self.cursor,
            .anchor = self.anchor,
        }) catch {
            self.gpa.free(current);
            self.gpa.free(change.text);
            return;
        };
        node.text.clearRetainingCapacity();
        node.text.appendSlice(self.gpa, change.text) catch {};
        self.gpa.free(change.text);
        self.selected = change.turn;
        self.cursor = @min(change.cursor, node.text.items.len);
        self.anchor = @min(change.anchor, node.text.items.len);
    }

    // ── Revisions ───────────────────────────────────────────────────────────

    pub fn revName(self: *Editor) []const u8 {
        return self.revs.items[self.current].name;
    }

    pub fn head(self: *Editor) Turn {
        return self.revs.items[self.current].head;
    }

    /// The current revision's turns, root first — or the read revision's, when one
    /// is being read.
    pub fn path(self: *Editor, out: *std.ArrayList(Turn)) !void {
        out.clearRetainingCapacity();
        var turn: ?Turn = self.revs.items[self.reading orelse self.current].head;
        while (turn) |at| {
            try out.append(self.gpa, at);
            turn = self.nodes.items[at].parent;
        }
        std.mem.reverse(Turn, out.items);
    }

    /// Adds a turn on the current revision, answering what the revision is at.
    pub fn add(self: *Editor, kind: Kind, content: []const u8) !Turn {
        const at = self.nodes.items.len;
        try self.nodes.append(self.gpa, .{ .kind = kind, .parent = self.head(), .rev = self.current });
        if (content.len != 0) try self.nodes.items[at].text.appendSlice(self.gpa, content);
        self.revs.items[self.current].head = at;
        self.selected = at;
        self.cursor = 0;
        return at;
    }

    /// Adds the empty prompt that follows a sent turn.
    pub fn newPrompt(self: *Editor) !Turn {
        return self.add(.prompt, "");
    }

    /// The prompt has been sent: its turn becomes a turn of the conversation,
    /// keeping its text and its place, and the revision's head stays on it so a
    /// reply streams from the turn it answers.
    pub fn markSent(self: *Editor) Turn {
        const at = self.revs.items[self.current].head;
        self.nodes.items[at].kind = .user;
        return at;
    }

    /// Adds an assistant turn to the current revision, by hand: what `/continue`
    /// was. The turn is appended after the revision's head, ready to be streamed
    /// into.
    pub fn appendAssistantTurn(self: *Editor) !Turn {
        return self.add(.assistant, "");
    }

    // ── Streams, which are revisions ────────────────────────────────────────

    /// Opens an assistant turn streaming on a revision of its own, off the turn
    /// the reply answers. Several may be open at once.
    pub fn beginAssistant(self: *Editor) !Stream {
        const parent = self.revs.items[self.current].head;
        var buffer: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&buffer, "assistant-{d}", .{self.revs.items.len});
        const rev = self.revs.items.len;
        try self.revs.append(self.gpa, .{ .name = try self.gpa.dupe(u8, label), .head = 0 });

        const at = self.nodes.items.len;
        try self.nodes.append(self.gpa, .{ .kind = .assistant, .parent = parent, .rev = rev });
        self.revs.items[rev].head = at;
        try self.open.append(self.gpa, at);
        return at;
    }

    pub fn appendAssistant(self: *Editor, stream: Stream, content: []const u8) !void {
        if (!self.isStreaming(stream)) return;
        try self.nodes.items[stream].text.appendSlice(self.gpa, content);
    }

    /// Closes a stream. A stream that was never merged stays a revision of its
    /// own, reachable by name.
    pub fn endAssistant(self: *Editor, stream: Stream) void {
        for (self.open.items, 0..) |open, i| {
            if (open == stream) {
                _ = self.open.orderedRemove(i);
                return;
            }
        }
    }

    /// Appends to a turn's text — what a reply streaming in does. When that turn
    /// is the one the editor is on, the cursor follows the text so the view
    /// stays where the writing is.
    pub fn appendText(self: *Editor, turn: Turn, content: []const u8) !void {
        if (turn >= self.nodes.items.len) return;
        try self.nodes.items[turn].text.appendSlice(self.gpa, content);
        if (turn == self.selected) {
            self.cursor = self.nodes.items[turn].text.items.len;
            self.anchor = self.cursor;
        }
    }

    pub fn isStreaming(self: *Editor, stream: Stream) bool {
        for (self.open.items) |open| {
            if (open == stream) return true;
        }
        return false;
    }

    pub fn streamCount(self: *Editor) usize {
        return self.open.items.len;
    }

    // ── Editor commands ─────────────────────────────────────────────────────

    pub fn revCount(self: *Editor) usize {
        return self.revs.items.len;
    }

    pub fn revNameAt(self: *Editor, index: usize) []const u8 {
        if (index >= self.revs.items.len) return "";
        return self.revs.items[index].name;
    }

    pub fn findRev(self: *Editor, name: []const u8) ?usize {
        for (self.revs.items, 0..) |rev, i| {
            if (std.mem.eql(u8, rev.name, name)) return i;
        }
        return null;
    }

    /// Reads a revision (`/tan`, as a key): what is drawn becomes this revision and
    /// nothing is written to it. The revision being typed into does not change,
    /// so no turn is sent to the revision that was forked off — the difference
    /// from omp's `/tan`.
    pub fn readRev(self: *Editor, index: usize) bool {
        if (index >= self.revs.items.len) return false;
        self.reading = index;
        return true;
    }

    pub fn stopReading(self: *Editor) void {
        self.reading = null;
    }

    pub fn readingName(self: *Editor) ?[]const u8 {
        const index = self.reading orelse return null;
        return self.revs.items[index].name;
    }

    /// Opens a side question (`/btw`): a revision of its own, holding the
    /// question, with an assistant turn already open to stream the answer into.
    /// The current revision is left alone, so the answer joins nothing.
    pub fn beginBtw(self: *Editor, question: []const u8) !Stream {
        var buffer: [32]u8 = undefined;
        const label = try std.fmt.bufPrint(&buffer, "btw-{d}", .{self.revs.items.len});
        const rev = self.revs.items.len;
        try self.revs.append(self.gpa, .{ .name = try self.gpa.dupe(u8, label), .head = 0 });

        const asked = self.nodes.items.len;
        try self.nodes.append(self.gpa, .{ .kind = .user, .parent = self.revs.items[self.current].head, .rev = rev });
        if (question.len != 0) try self.nodes.items[asked].text.appendSlice(self.gpa, question);
        self.revs.items[rev].head = asked;

        const answer = self.nodes.items.len;
        try self.nodes.append(self.gpa, .{ .kind = .assistant, .parent = asked, .rev = rev });
        self.revs.items[rev].head = answer;
        try self.open.append(self.gpa, answer);
        return answer;
    }

    /// Merges a stream into the current revision: the turn becomes the
    /// revision's next turn, still carrying the turn it forked from as its
    /// parent. The revision keeps its name.
    pub fn merge(self: *Editor, stream: Stream) !void {
        const node = &self.nodes.items[stream];
        node.parent = self.head();
        node.rev = self.current;
        self.revs.items[self.current].head = stream;
        self.endAssistant(stream);
        self.selected = stream;
        self.cursor = node.text.items.len;
    }

    // ── The turn being edited ───────────────────────────────────────────────

    /// Points the cursor at a turn — any turn, not only the head. This is the
    /// retroactive edit: what it says changes, and nothing moves.
    pub fn select(self: *Editor, turn: Turn) void {
        if (turn >= self.nodes.items.len) return;
        self.selected = turn;
        self.cursor = self.nodes.items[turn].text.items.len;
        self.anchor = self.cursor;
    }

    pub fn selectedKind(self: *Editor) Kind {
        return self.nodes.items[self.selected].kind;
    }

    pub fn turnText(self: *Editor, turn: Turn) []const u8 {
        if (turn >= self.nodes.items.len) return "";
        return self.nodes.items[turn].text.items;
    }

    pub fn turnKind(self: *Editor, turn: Turn) Kind {
        if (turn >= self.nodes.items.len) return .output;
        return self.nodes.items[turn].kind;
    }

    pub fn selectedRev(self: *Editor) []const u8 {
        return self.revs.items[self.nodes.items[self.selected].rev].name;
    }

    pub fn text(self: *Editor) []const u8 {
        return self.nodes.items[self.selected].text.items;
    }

    pub fn replaceText(self: *Editor, content: []const u8) !void {
        const node = &self.nodes.items[self.selected];
        node.text.clearRetainingCapacity();
        try node.text.appendSlice(self.gpa, content);
        self.cursor = 0;
        self.anchor = 0;
    }

    pub fn insertByte(self: *Editor, byte: u8) void {
        const node = &self.nodes.items[self.selected];
        node.text.insert(self.gpa, self.cursor, byte) catch return;
        self.cursor += 1;
    }

    /// Removes the bytes in `[from, to)` of the selected turn, and keeps both ends
    /// of the selection inside what is left. A caller may hand ends that no
    /// longer exist — the text can have shrunk under them — and this is where
    /// that is made safe rather than trusted.
    pub fn remove(self: *Editor, from: usize, to: usize) void {
        const node = &self.nodes.items[self.selected];
        const length = node.text.items.len;
        const end = @min(to, length);
        const start = @min(from, end);
        if (end <= start) {
            if (from > to) {
                self.cursor = @min(self.cursor, length);
                self.anchor = @min(self.anchor, length);
            }
            return;
        }
        std.mem.copyForwards(u8, node.text.items[start..], node.text.items[end..]);
        node.text.items.len -= end - start;
        self.cursor = start;
        self.anchor = @min(self.anchor, node.text.items.len);
    }

    pub fn moveCursor(self: *Editor, index: usize) void {
        self.cursor = @min(index, self.text().len);
        self.anchor = self.cursor;
    }

    /// Moves the cursor without moving the anchor: the text between them is the
    /// selection. This is what a motion does.
    pub fn stepTo(self: *Editor, index: usize) void {
        const length = self.text().len;
        self.cursor = @min(index, length);
        self.anchor = @min(self.anchor, length);
    }

    /// The selection, lower end first.
    pub const Range = struct { start: usize, end: usize };

    pub fn selection(self: *Editor) Range {
        const length = self.text().len;
        const anchor = @min(self.anchor, length);
        const cursor = @min(self.cursor, length);
        return .{ .start = @min(anchor, cursor), .end = @max(anchor, cursor) };
    }

    /// Reduces the selection to its cursor (`;`).
    pub fn collapse(self: *Editor) void {
        self.anchor = self.cursor;
    }

    /// Deletes the selection and leaves the cursor at its start.
    pub fn deleteSelection(self: *Editor) void {
        const range = self.selection();
        self.remove(range.start, range.end);
        self.anchor = self.cursor;
    }

    /// Expands the selection to cover whole lines (`x`).
    pub fn selectLines(self: *Editor) void {
        const content = self.text();
        const range = self.selection();
        const start = lineStartAt(content, range.start);
        var end = lineEndAt(content, range.end);
        if (end < content.len) end += 1; // the newline, as Kakoune includes it
        self.anchor = start;
        self.cursor = end;
    }

    /// Selects the whole turn (`%`).
    pub fn selectAll(self: *Editor) void {
        self.anchor = 0;
        self.cursor = self.text().len;
    }

    /// Inserts a newline below the line the cursor is on and puts the cursor
    /// there, ready to type (`o`).
    pub fn openBelow(self: *Editor) void {
        const content = self.text();
        const end = lineEndAt(content, self.cursor);
        self.anchor = end;
        self.cursor = end;
        self.insertByte('\n');
        self.anchor = self.cursor;
    }

    /// The same, above (`O`).
    pub fn openAbove(self: *Editor) void {
        const content = self.text();
        const start = lineStartAt(content, self.cursor);
        self.anchor = start;
        self.cursor = start;
        self.insertByte('\n');
        self.anchor = self.cursor;
    }

    pub fn cursorLineStart(self: *Editor) usize {
        return self.cursor - self.cursorColumn();
    }

    /// Moves the cursor to the next turn drawn — a retroactive edit's way in,
    /// since it can point at any turn and not only the head.
    pub fn selectNext(self: *Editor) void {
        self.stepSelection(1);
    }

    pub fn selectPrevious(self: *Editor) void {
        self.stepSelection(-1);
    }

    fn stepSelection(self: *Editor, delta: isize) void {
        var turns: std.ArrayList(Turn) = .empty;
        defer turns.deinit(self.gpa);
        self.view(&turns) catch return;
        for (turns.items, 0..) |turn, i| {
            if (turn != self.selected) continue;
            const target = @as(isize, @intCast(i)) + delta;
            if (target < 0 or target >= @as(isize, @intCast(turns.items.len))) return;
            self.select(turns.items[@intCast(target)]);
            return;
        }
    }

    // ── The view: the revision, then whatever is streaming ──────────────────

    /// The turns drawn, in order: the current revision's path, then each open
    /// stream — a side reply appears beside the revision, not inside it.
    pub fn view(self: *Editor, out: *std.ArrayList(Turn)) !void {
        try self.path(out);
        for (self.open.items) |stream| try out.append(self.gpa, stream);
    }

    pub fn lineCount(self: *Editor) usize {
        var turns: std.ArrayList(Turn) = .empty;
        defer turns.deinit(self.gpa);
        self.view(&turns) catch return 1;
        var count: usize = 0;
        for (turns.items) |turn| count += linesOf(self.nodes.items[turn].text.items);
        return @max(count, 1);
    }

    pub fn line(self: *Editor, index: usize) []const u8 {
        var turns: std.ArrayList(Turn) = .empty;
        defer turns.deinit(self.gpa);
        self.view(&turns) catch return &.{};
        var remaining = index;
        for (turns.items) |turn| {
            const turn_text = self.nodes.items[turn].text.items;
            const count = linesOf(turn_text);
            if (remaining < count) return lineOf(turn_text, remaining);
            remaining -= count;
        }
        return &.{};
    }

    /// Which line the cursor sits on, counting the turns drawn before it.
    pub fn cursorLine(self: *Editor) usize {
        var turns: std.ArrayList(Turn) = .empty;
        defer turns.deinit(self.gpa);
        self.view(&turns) catch return 0;
        var row: usize = 0;
        for (turns.items) |turn| {
            if (turn == self.selected) break;
            row += linesOf(self.nodes.items[turn].text.items);
        }
        for (self.text()[0..@min(self.cursor, self.text().len)]) |byte| {
            if (byte == '\n') row += 1;
        }
        return row;
    }

    /// The cursor's byte offset into its line.
    pub fn cursorColumn(self: *Editor) usize {
        const line_text = self.text()[0..@min(self.cursor, self.text().len)];
        if (std.mem.lastIndexOfScalar(u8, line_text, '\n')) |index| return line_text.len - index - 1;
        return line_text.len;
    }
};

/// The byte index where the line containing `index` starts.
fn lineStartAt(content: []const u8, index: usize) usize {
    return (std.mem.lastIndexOfScalar(u8, content[0..index], '\n') orelse return 0) + 1;
}

/// The byte index where the line containing `index` ends, before its newline.
fn lineEndAt(content: []const u8, index: usize) usize {
    if (std.mem.indexOfScalar(u8, content[index..], '\n')) |offset| return index + offset;
    return content.len;
}

/// How many lines a turn's text has.
fn linesOf(content: []const u8) usize {
    var count: usize = 1;
    for (content) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

/// One line of a turn's text, without its newline.
fn lineOf(content: []const u8, index: usize) []const u8 {
    var start: usize = 0;
    var at: usize = 0;
    while (at < index) : (at += 1) {
        const newline = std.mem.indexOfScalar(u8, content[start..], '\n') orelse return &.{};
        start += newline + 1;
    }
    const end = std.mem.indexOfScalar(u8, content[start..], '\n') orelse content.len - start;
    return content[start .. start + end];
}

test "a sent turn, its reply and the next prompt stay on the path" {
    var editor = try Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.replaceText("ask");
    _ = editor.markSent();
    const reply = try editor.appendAssistantTurn();
    try editor.appendText(reply, "answer");
    _ = try editor.newPrompt();

    var path: std.ArrayList(Turn) = .empty;
    defer path.deinit(std.testing.allocator);
    try editor.path(&path);
    try std.testing.expectEqual(@as(usize, 3), path.items.len);
    try std.testing.expectEqual(Kind.prompt, editor.turnKind(path.items[0]));
    try std.testing.expectEqual(Kind.user, editor.turnKind(path.items[1]));
    try std.testing.expectEqual(Kind.assistant, editor.turnKind(path.items[2]));
    try std.testing.expectEqualStrings("ask", editor.turnText(path.items[1]));
    try std.testing.expectEqualStrings("answer", editor.turnText(path.items[2]));
}

test "a selection cannot outlive the text it pointed at" {
    var editor = try Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.replaceText("abc");
    editor.selectAll();
    try std.testing.expectEqual(@as(usize, 0), editor.selection().start);
    try std.testing.expectEqual(@as(usize, 3), editor.selection().end);

    // The text shrinks under the selection; typing then must not read past it.
    editor.remove(0, 3);
    try std.testing.expectEqual(@as(usize, 0), editor.selection().start);
    try std.testing.expectEqual(@as(usize, 0), editor.selection().end);
    editor.deleteSelection();
    editor.insertByte('x');
    try std.testing.expectEqualStrings("x", editor.text());
}

test "undo puts a turn's text back, and a new change drops the redo" {
    var editor = try Editor.init(std.testing.allocator);
    defer editor.deinit();

    editor.record();
    try editor.replaceText("typed");
    try std.testing.expectEqualStrings("typed", editor.text());

    try std.testing.expect(editor.undo());
    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expect(editor.redo());
    try std.testing.expectEqualStrings("typed", editor.text());

    // A fresh change after an undo clears what could have been redone.
    try std.testing.expect(editor.undo());
    editor.record();
    try editor.replaceText("other");
    try std.testing.expect(!editor.redo());
    try std.testing.expectEqualStrings("other", editor.text());
}

test "revs stream together, a merge keeps the rev name, an edit is retroactive" {
    var editor = try Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.replaceText("first prompt");
    _ = try editor.add(.user, "first prompt\n");

    const main_reply = try editor.beginAssistant();
    const side_reply = try editor.beginAssistant();
    try editor.appendAssistant(main_reply, "the answer\n");
    try editor.appendAssistant(side_reply, "a side note\n");
    try editor.endAssistant(side_reply);

    // The rev is still `main`, and the side stream is drawn after it.
    try std.testing.expectEqualStrings("main", editor.revName());
    try std.testing.expectEqual(@as(usize, 1), editor.streamCount());
    try std.testing.expectEqualStrings("first prompt", editor.line(0));
    try std.testing.expectEqualStrings("the answer", editor.line(1));
    try std.testing.expectEqualStrings("a side note", editor.line(2));

    // Merging the side stream puts it on the rev, and the name holds.
    try editor.merge(side_reply);
    try std.testing.expectEqualStrings("main", editor.revName());
    try std.testing.expectEqualStrings("a side note", editor.line(1));
    try std.testing.expectEqualStrings("the answer", editor.line(2));

    // Editing the first turn keeps the rev and does not disturb the rest.
    editor.select(0);
    try editor.replaceText("edited prompt");
    try std.testing.expectEqualStrings("main", editor.selectedRev());
    try std.testing.expectEqualStrings("edited prompt", editor.line(0));
    try std.testing.expectEqualStrings("a side note", editor.line(1));
    try std.testing.expectEqual(@as(usize, 3), editor.lineCount());
}
