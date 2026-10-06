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
//! The keys are the `bindings` table below, and `:keys` draws that table as a
//! sheet over the tree. Two of the splits it records are worth stating here:
//!
//!   * `j k` move within the text, the arrows move between turns, and `} {` do
//!     what the arrows do but select what they land on — a retroactive edit's
//!     way in.
//!   * `:` is this harness's own command line, and Tab is IPython's. They are
//!     different languages, so they are different lines: a name after `:` that
//!     is not a command is refused, and a Python line is never mistaken for one.
//!
//! Editing goes by grapheme, not by byte, and columns are counted in the cells
//! kitty draws. Long lines wrap. Every terminal call is `kitty.zig`, and the
//! shell is `ipython.zig`.
//!
//! Sessions are the world's: `session.zig` owns the file, `editor.zig` writes a
//! turn tree into it and reads one back, `-c` becomes the last session and
//! `--resume` opens the picker over every one of them, and what a run leaves
//! behind is filed on the way out. A resumed run that said nothing new is not
//! filed again.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const kitty = @import("kitty.zig");
const ipython = @import("ipython.zig");
const editor = @import("editor.zig");
const row = @import("row.zig");
const theme = @import("theme.zig");
const screen = @import("screen.zig");
const markup = @import("markup.zig");
const pikchr = @import("pikchr.zig");
const graphics = @import("graphics.zig");
const model = @import("model.zig");
const session = @import("session.zig");
const debug = run1.debug;
const lithos = run1.lithos;

/// How many times the model may call tools before the round loop gives up.
const max_rounds = 8;

pub fn run(init: std.process.Init, options: Options) !void {
    var tui = try Tui.init(init.gpa, init.io, init.environ_map);
    defer tui.deinit();
    tui.begin(options);
    // Python reaches the harness through this: `run1.ask`, `run1.turns` and
    // `run1.system_prompt` from the command line or from the python tool.
    ipython.setHost(hostCall, &tui);
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
        if (try tui.pressKey(key)) break;
        tui.render();
    }
    // What the run leaves behind is written on the way out, so the next one can
    // resume it.
    tui.save();
}

const Mode = enum {
    normal,
    insert,
    /// The harness's command line, over `:`.
    command,
    /// IPython's line, over Tab.
    shell,
    /// The `:keys` reference, drawn in place of the tree.
    sheet,
    /// The sessions on disk, drawn in place of the tree, waiting to be picked.
    picking,
};

/// What the command line asked for, from `ui/main.zig`: no flags is a fresh
/// session, and the store is still written on the way out.
pub const Options = struct {
    /// `-c`: become the last session the store holds.
    resume_last: bool = false,
    /// `--resume`: open the picker over what it holds.
    resume_pick: bool = false,
};

/// One command the harness's own command line takes: its name, what it does,
/// and what runs it. The name is the harness's; anything else typed after `:`
/// is refused, because that line is not a language.
const Command = struct {
    name: []const u8,
    what: []const u8,
    run: *const fn (*Tui) void,
};

const commands = [_]Command{
    .{ .name = "keys", .what = "the key reference", .run = Tui.showKeys },
};

/// One line of the sheet `:keys` draws.
const Binding = struct {
    keys: []const u8,
    what: []const u8,
};

/// The key reference, by mode. It is the contract the handlers below keep: a
/// key that changes belongs here in the same change, and the sheet is this.
const bindings = struct {
    const normal = [_]Binding{
        .{ .keys = "h j k l", .what = "left, down, up, right, within the text" },
        .{ .keys = "w b e", .what = "word forward, back, and to the word's end" },
        .{ .keys = "i a I A", .what = "insert before, after, at the line's start, at its end" },
        .{ .keys = "o O", .what = "open a line below, above" },
        .{ .keys = "d c", .what = "delete the selection, or delete it and insert" },
        .{ .keys = "x % ;", .what = "the whole lines, the whole turn, collapse the selection" },
        .{ .keys = "u <a-u>", .what = "undo, redo — one run of typing undoes as one" },
        .{ .keys = "<a-b>", .what = "ask the prompt as a side question, on a revision of its own" },
        .{ .keys = "<a-t>", .what = "read the next revision: a view, nothing is written to it" },
        .{ .keys = "<a-m>", .what = "the tags the selected turn was generated with" },
        .{ .keys = "C", .what = "append an assistant turn by hand — what `/continue` was" },
    };
    const turns = [_]Binding{
        .{ .keys = "<up> <down>", .what = "the previous, next turn" },
        .{ .keys = "} {", .what = "the same, selecting what they land on" },
    };
    const insert = [_]Binding{
        .{ .keys = "<enter>", .what = "send it: `!command` runs in fish, anything else the script's `add_turn`" },
        .{ .keys = "<shift-enter>", .what = "a newline, so a prompt can be several lines" },
        .{ .keys = "<esc>", .what = "back to normal mode" },
    };
    const lines = [_]Binding{
        .{ .keys = ":", .what = "the harness's command line" },
        .{ .keys = "<tab>", .what = "the IPython line" },
        .{ .keys = "<ctl-c>", .what = "leave run1" },
    };
    const command = [_]Binding{
        .{ .keys = "<enter>", .what = "run the command" },
        .{ .keys = "<esc>", .what = "back to the tree" },
    };
    const shell = [_]Binding{
        .{ .keys = "<enter>", .what = "run the line in the shell" },
        .{ .keys = "<tab>", .what = "complete the word before the cursor" },
        .{ .keys = "<up> <down>", .what = "the shell's history" },
        .{ .keys = "<ctl-d>", .what = "back to the tree" },
    };
    const sheet = [_]Binding{
        .{ .keys = "<up> <down>", .what = "scroll" },
        .{ .keys = "<esc> q", .what = "back to the tree" },
    };
    const picker = [_]Binding{
        .{ .keys = "<up> <down>", .what = "the session to resume" },
        .{ .keys = "<enter>", .what = "resume it" },
        .{ .keys = "<esc> q", .what = "start a fresh one" },
    };
};

/// One section of the sheet: a mode, and its keys.
const Section = struct { name: []const u8, rows: []const Binding };

const sections = [_]Section{
    .{ .name = "normal mode", .rows = &bindings.normal },
    .{ .name = "turns", .rows = &bindings.turns },
    .{ .name = "insert mode", .rows = &bindings.insert },
    .{ .name = "lines", .rows = &bindings.lines },
    .{ .name = "command mode", .rows = &bindings.command },
    .{ .name = "IPython mode", .rows = &bindings.shell },
    .{ .name = "this sheet", .rows = &bindings.sheet },
    .{ .name = "the picker", .rows = &bindings.picker },
};

const Tui = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    doc: editor.Editor,
    /// Here so the status row can say a reply is streaming in.
    streaming: ?editor.Stream = null,
    /// The command line, kept apart from the prompt.
    command: std.ArrayList(u8) = .empty,
    command_cursor: usize = 0,
    /// The prompt the shell's line opens with — `In [n]: `, the number the
    /// shell's own counter is on. Read when the line opens, not while it is
    /// drawn: the number moves only when a line runs.
    shell_prompt_buffer: [32]u8 = undefined,
    shell_prompt: []const u8 = "In [1]: ",
    /// The harness's own command line, over `:` — a different line from the
    /// shell's, because a command and a Python line are different languages.
    line: std.ArrayList(u8) = .empty,
    line_cursor: usize = 0,
    /// The `:keys` sheet, drawn in place of the tree while it is open. Owned.
    sheet: ?[]const u8 = null,
    /// The world the sessions live in, or null when it could not be opened: a
    /// session that cannot be kept is not a reason to refuse to run.
    world: ?run1.world.World = null,
    /// The session the picker is on.
    pick: usize = 0,
    /// The turns a resume brought in. A run that added none of its own is that
    /// session again, and filing it a second time would fill the picker with
    /// copies of it.
    resumed_with: usize = 0,
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
    /// The commands a ```pikchr fence is drawn with, when this machine has
    /// them; null when it does not, and then the fence stays text.
    diagrams: ?pikchr.Tools = null,
    /// The pictures already rendered and transmitted, keyed by the fence's own
    /// text. A value with `id` zero is a fence that could not be drawn, kept so
    /// it is not retried on every frame.
    pictures: std.StringHashMap(markup.Diagrams.Diagram),

    fn init(gpa: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map) !Tui {
        var tui: Tui = .{
            .gpa = gpa,
            .io = io,
            .environ_map = environ_map,
            .doc = try editor.Editor.init(gpa),
            .frame = screen.Screen.init(gpa),
            .pictures = std.StringHashMap(markup.Diagrams.Diagram).init(gpa),
        };
        // A store that cannot be opened is not a reason to refuse to run: the
        // session is simply not kept.
        tui.world = session.open(gpa, io, environ_map) catch null;
        // A machine without pikchr simply draws the fence as text; the probe is
        // here, once, so no frame pays for it.
        tui.diagrams = pikchr.Tools.find(io, gpa);
        return tui;
    }

    /// Takes the flags. Called once the caller owns the returned struct: a
    /// status set inside `init` would point into the copy it was built in.
    fn begin(self: *Tui, options: Options) void {
        const total = self.sessionCount();
        if (options.resume_pick) {
            if (total == 0) {
                self.setStatus("no sessions to resume yet", .{});
            } else {
                self.mode = .picking;
                self.pick = total - 1;
            }
        } else if (options.resume_last) {
            if (total == 0) {
                self.setStatus("no sessions to resume yet", .{});
            } else if (self.world) |*w| {
                if (self.doc.restore(w, total - 1)) |_| {
                    self.resumed_with = self.doc.nodes.items.len;
                    self.setStatus("resumed {s}", .{session.name(w, total - 1)});
                } else |_| self.setStatus("the last session could not be read", .{});
            }
        }
    }

    fn deinit(self: *Tui) void {
        self.doc.deinit();
        self.command.deinit(self.gpa);
        self.draft.deinit(self.gpa);
        self.line.deinit(self.gpa);
        if (self.sheet) |text| self.gpa.free(text);
        var keys = self.pictures.keyIterator();
        while (keys.next()) |key| self.gpa.free(key.*);
        self.pictures.deinit();
        if (self.world) |*w| w.deinit();
        self.frame.deinit();
    }

    /// How many sessions the store holds; none when it did not open.
    fn sessionCount(self: *Tui) usize {
        if (self.world) |*w| return session.count(w);
        return 0;
    }

    /// Writes what this run leaves behind, unless it said nothing: an empty run
    /// is not worth a row in the picker.
    fn save(self: *Tui) void {
        if (self.doc.nodes.items.len == self.resumed_with) return;
        const filing = self.label() orelse return;
        if (self.world) |*w| {
            self.doc.save(w, filing) catch |err| {
                // The picker will not show this run, and silence would read as
                // a resume that forgot: a store that ran out of room says so.
                var buffer: [256]u8 = undefined;
                var stderr_file = Io.File.stderr().writerStreaming(self.io, &buffer);
                var logger = debug.writer(&stderr_file.interface);
                logger.report("session:not_filed", "{t}", .{err});
                stderr_file.interface.flush() catch {};
            };
        }
    }

    /// What the run is filed under: the first thing said in it, one line, cut
    /// to what a picker row holds.
    fn label(self: *Tui) ?[]const u8 {
        var path: std.ArrayList(editor.Turn) = .empty;
        defer path.deinit(self.gpa);
        self.doc.path(&path) catch return null;
        for (path.items) |turn| {
            if (self.doc.turnKind(turn) != .user) continue;
            const said = self.doc.turnText(turn);
            if (said.len == 0) continue;
            const line = std.mem.sliceTo(said, '\n');
            return line[0..@min(line.len, 64)];
        }
        return null;
    }

    // ── The picker ──────────────────────────────────────────────────────────

    fn pickerKey(self: *Tui, key: kitty.Key) bool {
        const total = self.sessionCount();
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                'j' => if (self.pick + 1 < total) {
                    self.pick += 1;
                },
                'k' => if (self.pick > 0) {
                    self.pick -= 1;
                },
                '\r', '\n' => self.resumePicked(),
                'q', 0x1b => self.startFresh(),
                else => {},
            },
            .down => if (self.pick + 1 < total) {
                self.pick += 1;
            },
            .up => if (self.pick > 0) {
                self.pick -= 1;
            },
            .home => self.pick = 0,
            .end => self.pick = if (total == 0) 0 else total - 1,
            .escape => self.startFresh(),
            else => {},
        }
        return false;
    }

    /// Enter: the marked session becomes this editor's tree.
    fn resumePicked(self: *Tui) void {
        if (self.world) |*w| {
            const picked = self.pick;
            if (self.doc.restore(w, picked)) |_| {
                self.resumed_with = self.doc.nodes.items.len;
                self.mode = .normal;
                self.setStatus("resumed {s}", .{session.name(w, picked)});
                return;
            } else |_| {}
        }
        self.mode = .normal;
        self.setStatus("that session could not be read", .{});
    }

    /// The way out that does not resume: the picker closes and the tree is the
    /// fresh one this run started with.
    fn startFresh(self: *Tui) void {
        self.mode = .normal;
        self.setStatus("a fresh session", .{});
    }

    /// The sessions as rows, newest last, with the one Enter would take marked.
    fn pickerRows(self: *Tui, out: *std.ArrayList([]u8), width: usize) !void {
        const total = self.sessionCount();
        if (total == 0) {
            try out.append(self.gpa, try self.gpa.dupe(u8, "no sessions yet"));
            return;
        }
        for (0..total) |index| {
            const filed = if (self.world) |*w| session.name(w, index) else "";
            const name = if (filed.len == 0) "(unnamed)" else filed;
            const mark = if (index == self.pick) "› " else "  ";
            const painted = if (index == self.pick)
                try theme.paint(self.gpa, theme.accent, name)
            else
                try self.gpa.dupe(u8, name);
            defer self.gpa.free(painted);
            const kept = try row.truncate(self.gpa, painted, if (width > 2) width - 2 else 1);
            defer self.gpa.free(kept);
            try out.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ mark, kept }));
        }
    }

    fn setStatus(self: *Tui, comptime format: []const u8, args: anytype) void {
        self.status = std.fmt.bufPrint(&self.status_buffer, format, args) catch self.status_buffer[0..0];
    }

    fn pressKey(self: *Tui, key: kitty.Key) !bool {
        // A message is about the key that produced it, so the next key clears
        // it rather than leaving it to look like state.
        self.status = "";
        return switch (self.mode) {
            .normal => self.normalKey(key),
            .insert => self.insertKey(key),
            .command => self.commandKey(key),
            .shell => self.shellKey(key),
            .sheet => self.sheetKey(key),
            .picking => self.pickerKey(key),
        };
    }

    // ── Normal mode, as Kakoune's ───────────────────────────────────────────

    fn normalKey(self: *Tui, key: kitty.Key) bool {
        const text = self.doc.text();
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                9 => self.enterShell(), // Tab: IPython's line
                ':' => self.enterCommand(), // and `:` for this harness's own
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
                '}' => self.focusTurn(1),
                '{' => self.focusTurn(-1),
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
            .up => self.focusTurn(-1),
            .down => self.focusTurn(1),
            .home => self.doc.stepTo(self.doc.cursorLineStart()),
            .end => self.doc.stepTo(lineEnd(text, self.doc.cursorLineStart())),
            .delete => self.doc.deleteSelection(),
            .shift_enter, .eof, .unknown => {},
        }
        return false;
    }

    /// The arrows, `}` and `{`: focus the turn after this one, or before it.
    /// The cursor lands at that turn's end with nothing selected, so the next
    /// motion and the next key start from it. `j` and `k` stay line motions —
    /// the arrows move between turns, the editing keys move within the text.
    fn focusTurn(self: *Tui, delta: isize) void {
        if (delta < 0) {
            self.doc.selectPrevious();
        } else {
            self.doc.selectNext();
        }
        self.setStatus("{s} on {s}", .{ @tagName(self.doc.selectedKind()), self.doc.selectedRev() });
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
                9 => self.enterShell(), // Tab: IPython's line
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
        if (std.mem.startsWith(u8, sent, "!")) {
            const command = std.mem.trimStart(u8, sent[1..], " \t");
            const output = ipython.fish(self.gpa, command) catch {
                self.status = "the scripting layer failed";
                return;
            };
            defer self.gpa.free(output);
            _ = self.doc.markSent();
            const turn = self.doc.appendAssistantTurn() catch return;
            self.doc.appendText(turn, output) catch {};
            self.doc.tag(turn, "source", "fish") catch {};
            _ = self.doc.newPrompt() catch {};
            return;
        }

        // The script records the turn; the reply comes from the model.
        if (ipython.addTurn(self.gpa, sent)) |recorded| {
            self.gpa.free(recorded);
        } else |_| {}

        _ = self.doc.markSent();

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // The harness's own words first: what this is, the feature vocabulary,
        // and that an instruction may be declined rather than obeyed.
        var harness_prompt: Io.Writer.Allocating = .init(self.gpa);
        defer harness_prompt.deinit();
        run1.system_prompt.systemPrompt(&harness_prompt.writer) catch {};

        var messages: std.ArrayList(lithos.chat.Message) = .empty;
        messages.append(arena, .{ .system = .{ .content = lithos.chat.text(harness_prompt.written()) } }) catch {};

        // Then the revision's path: the turns sent and answered so far, read
        // before this reply's own turn exists — a request ending in an empty
        // assistant turn asks the model to continue nothing.
        var path: std.ArrayList(editor.Turn) = .empty;
        defer path.deinit(self.gpa);
        self.doc.path(&path) catch {};
        for (path.items) |turn| {
            const kind = self.doc.turnKind(turn);
            if (kind != .user and kind != .assistant) continue;
            const said = self.doc.turnText(turn);
            messages.append(arena, switch (kind) {
                .user => .{ .user = .{ .content = lithos.chat.text(said) } },
                else => .{ .assistant = .{ .content = .{ .text = said } } },
            }) catch {};
        }

        var reason: std.ArrayList(u8) = .empty;
        defer reason.deinit(self.gpa);
        var log: Io.Writer.Allocating = .init(self.gpa);
        defer log.deinit();
        var calls: std.ArrayList(model.ToolCall) = .empty;

        var round_index: usize = 0;
        while (round_index < max_rounds) : (round_index += 1) {
            // Each round answers into a turn of its own, so an exchange that
            // used a tool reads in order: what it said, what the tool printed,
            // what it said next.
            const turn = self.doc.appendAssistantTurn() catch break;
            self.streaming = turn;
            calls.clearRetainingCapacity();

            model.round(self.gpa, self.io, self.environ_map, debug.writer(&log.writer), messages.items, &calls, arena, &reason, .{
                .context = self,
                .write = appendChunk,
            }) catch {
                const why = if (reason.items.len != 0) reason.items else "the model failed";
                self.doc.appendText(turn, why) catch {};
                self.setStatus("{s}", .{std.mem.sliceTo(why, '\n')});
                break;
            };

            // What made this turn, for `Alt-m`.
            self.doc.tag(turn, "model", model.default_model) catch {};
            self.doc.tag(turn, "thinking", @tagName(model.default_effort)) catch {};
            self.doc.tag(turn, "source", "model") catch {};

            if (calls.items.len == 0) break;

            // The turn that asked, then one result per call.
            const asked = arena.alloc(lithos.chat.ToolCall, calls.items.len) catch break;
            for (calls.items, 0..) |call, i| {
                asked[i] = .{ .id = call.id, .function = .{ .name = call.name, .arguments = call.arguments } };
            }
            messages.append(arena, .{ .assistant = .{
                .content = .{ .text = self.doc.turnText(turn) },
                .tool_calls = asked,
            } }) catch break;

            for (calls.items) |call| {
                const result = self.runTool(arena, call) catch "the tool could not run";
                messages.append(arena, .{ .tool = .{
                    .tool_call_id = call.id,
                    .content = lithos.chat.text(result),
                } }) catch break;
            }
        }

        self.streaming = null;
        _ = self.doc.newPrompt() catch {};
    }

    /// Runs one call the model made. A name outside the declared tools is
    /// answered as such rather than guessed at.
    fn runTool(self: *Tui, arena: std.mem.Allocator, call: model.ToolCall) ![]const u8 {
        const is_fish = std.mem.eql(u8, call.name, "fish");
        const is_python = std.mem.eql(u8, call.name, "python");
        if (!is_fish and !is_python) return "no such tool";

        const key = if (is_fish) "command" else "code";
        const source = argumentOf(self.gpa, call.arguments, key) orelse
            return if (is_fish) "the call carried no command" else "the call carried no code";
        defer self.gpa.free(source);

        const output = if (is_fish)
            try ipython.fish(self.gpa, source)
        else
            try ipython.run(self.gpa, source);
        defer self.gpa.free(output);

        // What was run, and what it printed, is a turn of its own.
        var shown: std.ArrayList(u8) = .empty;
        defer shown.deinit(self.gpa);
        try shown.appendSlice(self.gpa, call.name);
        try shown.appendSlice(self.gpa, ": ");
        try shown.appendSlice(self.gpa, source);
        try shown.appendSlice(self.gpa, "\n");
        try shown.appendSlice(self.gpa, output);
        _ = self.doc.add(.output, shown.items) catch {};

        return arena.dupe(u8, output);
    }

    /// One `run1` call. The answer is a c-allocator string, because that is
    /// what the shim frees; null is a method the harness does not answer.
    fn host(self: *Tui, method: []const u8, argument: []const u8) !?[*:0]u8 {
        const allocator = std.heap.c_allocator;
        const json = if (std.mem.eql(u8, method, "prompt"))
            try systemPromptText(allocator)
        else if (std.mem.eql(u8, method, "ask"))
            try self.hostAsk(allocator, argument)
        else if (std.mem.eql(u8, method, "turns"))
            try self.hostTurns(allocator)
        else if (std.mem.eql(u8, method, "add")) blk: {
            _ = self.doc.add(.output, argument) catch {};
            break :blk try allocator.dupe(u8, "");
        } else return null;
        defer allocator.free(json);
        return (try allocator.dupeSentinel(u8, json, 0)).ptr;
    }

    /// One exchange with the model — the prompt given, against the harness's
    /// own prompt and tools — answered as JSON: the reply text and the calls it
    /// asked for. A call that failed answers with its reason, so Python is told
    /// why rather than handed a silent nothing.
    fn hostAsk(self: *Tui, allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var log: Io.Writer.Allocating = .init(self.gpa);
        defer log.deinit();
        var reason: std.ArrayList(u8) = .empty;
        defer reason.deinit(self.gpa);

        const Call = struct { id: []const u8, name: []const u8, arguments: []const u8 };
        const Reply = struct { text: []const u8, tool_calls: []const Call };
        const Failed = struct { @"error": []const u8 };

        const reply = model.ask(self.gpa, self.io, self.environ_map, debug.writer(&log.writer), prompt, arena, &reason) catch |err| switch (err) {
            error.NoKey, error.RequestFailed => return std.json.Stringify.valueAlloc(allocator, Failed{ .@"error" = reason.items }, .{}),
            else => return err,
        };

        const calls = try allocator.alloc(Call, reply.calls.len);
        defer allocator.free(calls);
        for (reply.calls, calls) |call, *out| {
            out.* = .{ .id = call.id, .name = call.name, .arguments = call.arguments };
        }
        return std.json.Stringify.valueAlloc(allocator, Reply{ .text = reply.text, .tool_calls = calls }, .{});
    }

    /// The turns on the current path, as JSON: what the document holds, and
    /// what each turn is.
    fn hostTurns(self: *Tui, allocator: std.mem.Allocator) ![]u8 {
        var path: std.ArrayList(editor.Turn) = .empty;
        defer path.deinit(self.gpa);
        try self.doc.path(&path);

        const Row = struct { kind: []const u8, text: []const u8 };
        const rows = try allocator.alloc(Row, path.items.len);
        defer allocator.free(rows);
        for (path.items, rows) |turn, *out| {
            out.* = .{ .kind = @tagName(self.doc.turnKind(turn)), .text = self.doc.turnText(turn) };
        }
        return std.json.Stringify.valueAlloc(allocator, rows, .{});
    }

    /// A chunk of the reply, drawn the moment it lands. The chain of thought goes
    /// to the turn's reasoning, the answer to its text.
    fn appendChunk(context: *anyopaque, part: model.Part, chunk: []const u8) void {
        const self: *Tui = @ptrCast(@alignCast(context));
        const turn = self.streaming orelse return;
        switch (part) {
            .reasoning => self.doc.appendReasoning(turn, chunk) catch return,
            .content => self.doc.appendText(turn, chunk) catch return,
        }
        self.render();
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

    // ── Command mode, as Kakoune's ──────────────────────────────────────────

    /// `:`: this harness's own command line, which starts empty. The shell's
    /// line is Tab's, and the two are kept apart.
    fn enterCommand(self: *Tui) void {
        self.line.clearRetainingCapacity();
        self.line_cursor = 0;
        self.mode = .command;
    }

    fn commandKey(self: *Tui, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                4 => self.mode = .normal, // Ctrl-D, back to the tree
                '\r', '\n' => return self.runCommand(),
                0x7f, 0x08 => self.commandBackspace(),
                else => if (byte >= 0x20) self.commandInsert(byte),
            },
            .left => if (self.line_cursor > 0) {
                self.line_cursor -= 1;
            },
            .right => if (self.line_cursor < self.line.items.len) {
                self.line_cursor += 1;
            },
            .home => self.line_cursor = 0,
            .end => self.line_cursor = self.line.items.len,
            .delete => if (self.line_cursor < self.line.items.len) {
                _ = self.line.orderedRemove(self.line_cursor);
            },
            .escape => self.mode = .normal,
            .up, .down, .alt, .shift_enter, .eof, .unknown => {},
        }
        return false;
    }

    /// Runs what was typed after `:`. A name in `commands` runs; anything else
    /// is refused rather than guessed at.
    fn runCommand(self: *Tui) bool {
        const word = std.mem.trim(u8, self.line.items, " \t");
        defer {
            self.line.clearRetainingCapacity();
            self.line_cursor = 0;
        }
        self.mode = .normal;
        if (word.len == 0) return false;
        for (commands) |command| {
            if (std.mem.eql(u8, word, command.name)) {
                command.run(self);
                return false;
            }
        }
        self.setStatus("no such command: {s}", .{word});
        return false;
    }

    fn commandInsert(self: *Tui, byte: u8) void {
        self.line.insert(self.gpa, self.line_cursor, byte) catch return;
        self.line_cursor += 1;
    }

    fn commandBackspace(self: *Tui) void {
        if (self.line_cursor == 0) return;
        _ = self.line.orderedRemove(self.line_cursor - 1);
        self.line_cursor -= 1;
    }

    // ── The sheet ───────────────────────────────────────────────────────────

    /// `:keys`: the key reference, drawn in place of the tree. A view, in the
    /// sense `<a-t>` reads one: nothing is written, and no turn is made of it.
    fn showKeys(self: *Tui) void {
        const text = sheetText(self.gpa) catch {
            self.setStatus("could not build the sheet", .{});
            return;
        };
        if (self.sheet) |old| self.gpa.free(old);
        self.sheet = text;
        self.top = 0;
        self.mode = .sheet;
        self.setStatus("the key reference", .{});
    }

    fn closeSheet(self: *Tui) void {
        if (self.sheet) |text| self.gpa.free(text);
        self.sheet = null;
        self.mode = .normal;
    }

    fn sheetKey(self: *Tui, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                'j' => self.top += 1,
                'k' => self.top -|= 1,
                'q', 0x1b => self.closeSheet(),
                else => {},
            },
            .down => self.top += 1,
            .up => self.top -|= 1,
            .home => self.top = 0,
            .escape => self.closeSheet(),
            else => {},
        }
        return false;
    }

    // ── Command mode, as IPython's ──────────────────────────────────────────

    /// Hands the bottom row to the shell's line, carrying the prompt the shell
    /// is on now.
    fn enterShell(self: *Tui) void {
        self.shell_prompt = ipython.prompt(&self.shell_prompt_buffer) orelse "In [1]: ";
        self.mode = .shell;
    }

    fn shellKey(self: *Tui, key: kitty.Key) bool {
        switch (key) {
            .byte => |byte| switch (byte) {
                3 => return true, // Ctrl-C
                4 => self.mode = .normal, // Ctrl-D, back to the tree
                9 => self.shellComplete(),
                '\r', '\n' => return self.runShellLine(),
                0x7f, 0x08 => self.shellBackspace(),
                else => if (byte >= 0x20) self.shellInsert(byte),
            },
            .left => if (self.command_cursor > 0) {
                self.command_cursor -= 1;
            },
            .right => if (self.command_cursor < self.command.items.len) {
                self.command_cursor += 1;
            },
            .up => self.shellHistory(1),
            .down => self.shellHistory(-1),
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

    fn runShellLine(self: *Tui) bool {
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
    fn shellComplete(self: *Tui) void {
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
    fn shellHistory(self: *Tui, delta: isize) void {
        const next = @as(isize, @intCast(self.history_offset)) + delta;
        if (next < 0) return;
        if (next == 0) {
            if (self.history_offset != 0) self.setShellLine(self.draft.items);
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
        self.setShellLine(entry);
        self.history_offset = @intCast(next);
    }

    fn setShellLine(self: *Tui, text: []const u8) void {
        self.command.clearRetainingCapacity();
        self.command.appendSlice(self.gpa, text) catch {};
        self.command_cursor = self.command.items.len;
    }

    fn shellInsert(self: *Tui, byte: u8) void {
        self.command.insert(self.gpa, self.command_cursor, byte) catch return;
        self.command_cursor += 1;
    }

    fn shellBackspace(self: *Tui) void {
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
        if (self.mode == .picking) {
            self.pickerRows(&transcript, width) catch {};
            // The highlighted row is where the picker's cursor is, so the same
            // rule keeps it in view.
            cursor_row = self.pick;
        } else if (self.sheet) |text| {
            self.sheetRows(&transcript, text, width) catch {};
        } else {
            self.turnRows(&transcript, width, &cursor_row, &cursor_col) catch {};
        }

        // Keep the cursor in view, or — on the sheet, which has no cursor —
        // keep the scroll inside it.
        if (self.sheet == null) {
            if (cursor_row < self.top) self.top = cursor_row;
            if (cursor_row >= self.top + height) self.top = cursor_row + 1 - height;
        }
        if (transcript.items.len >= height and self.top + height > transcript.items.len) {
            self.top = transcript.items.len - height;
        }
        if (self.top > transcript.items.len) self.top = transcript.items.len;
        // The sheet is scrolled rather than kept in view, and its scroll stops
        // where the text does.
        if (self.sheet != null) {
            const limit = if (transcript.items.len > height) transcript.items.len - height else 0;
            if (self.top > limit) self.top = limit;
        }

        self.frame.clear();
        self.statusRow(width) catch {};
        var drawn: usize = 0;
        while (drawn < height) : (drawn += 1) {
            const index = self.top + drawn;
            if (index >= transcript.items.len) break;
            self.frame.add(transcript.items[index]) catch {};
        }

        switch (self.mode) {
            .command => {
                self.lineRow(self.rows - 1, width, ": ", self.line.items) catch {};
                self.frame.place(self.rows - 1, @min(self.line_cursor + 2, width - 1));
            },
            .shell => {
                self.lineRow(self.rows - 1, width, self.shell_prompt, self.command.items) catch {};
                self.frame.place(self.rows - 1, @min(self.command_cursor + self.shell_prompt.len, width - 1));
            },
            // The sheet is scrolled, not edited, so its rows are not a place a
            // cursor can be: the position it would have is not computed.
            .sheet => self.frame.place(self.rows - 1, 0),
            else => self.frame.place(1 + (cursor_row - self.top), @min(cursor_col, width - 1)),
        }
        self.frame.flush();
    }

    /// The sheet's rows: its lines, wrapped to the width, with no gutter and no
    /// cursor — nothing in it is edited.
    fn sheetRows(self: *Tui, out: *std.ArrayList([]u8), text: []const u8, width: usize) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var wrapped: std.ArrayList([]u8) = .empty;
            defer freeRows(self.gpa, &wrapped);
            try row.wrap(self.gpa, line, width, &wrapped);
            for (wrapped.items) |part| try out.append(self.gpa, try self.gpa.dupe(u8, part));
        }
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
        if (self.streaming != null or self.doc.streamCount() != 0) {
            try text.appendSlice(self.gpa, "  streaming");
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

    /// A line being typed, on row `at`: the rows between it and the transcript
    /// are filled, so the row is where the cursor is placed.
    fn lineRow(self: *Tui, at: usize, width: usize, prefix: []const u8, line: []const u8) !void {
        try self.frame.padTo(at);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.appendSlice(self.gpa, prefix);
        try text.appendSlice(self.gpa, line);
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
            const reasoning = self.doc.turnReasoning(turn);
            const is_selected = turn == self.doc.selected;
            const mark = gutterFor(self.doc.turnKind(turn));

            // The chain of thought is drawn dim, above the answer it came
            // before; the answer is highlighted when this is the turn being
            // edited. The mark goes on the first row only, continuation rows
            // are indented to match.
            var first_row = true;
            var content_start: ?usize = null;
            for ([_]bool{ true, false }) |is_reasoning| {
                const content = if (is_reasoning) reasoning else raw;
                if (content.len == 0) continue;
                if (!is_reasoning) content_start = out.items.len;

                // A reply is Djot, so a turn that is not being edited is drawn
                // as what it means — headings, emphasis, a rule, a picture. The
                // turn being edited is drawn as its own source, where the cursor
                // and the selection are exact; the chain of thought above it is
                // dim, and is not Djot to begin with.
                if (!is_reasoning and !is_selected) {
                    var rendered = markup.render(self.gpa, content, inner, .{ .ctx = self, .resolve = resolveDiagram }) catch null;
                    if (rendered) |*rows| {
                        defer {
                            for (rows.items) |text| self.gpa.free(text);
                            rows.deinit(self.gpa);
                        }
                        for (rows.items) |text| {
                            const entry = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ if (first_row) mark else "  ", text });
                            errdefer self.gpa.free(entry);
                            try out.append(self.gpa, entry);
                            first_row = false;
                        }
                        continue;
                    }
                }

                const styled = if (is_reasoning)
                    try theme.paint(self.gpa, theme.dim, content)
                else if (is_selected)
                    try theme.highlight(self.gpa, content, range.start, range.end)
                else
                    try self.gpa.dupe(u8, content);
                defer self.gpa.free(styled);

                var lines = std.mem.splitScalar(u8, styled, '\n');
                while (lines.next()) |line| {
                    var wrapped: std.ArrayList([]u8) = .empty;
                    defer freeRows(self.gpa, &wrapped);
                    try row.wrap(self.gpa, line, inner, &wrapped);
                    for (wrapped.items, 0..) |text, i| {
                        const prefix = if (first_row and i == 0) mark else "  ";
                        const entry = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ prefix, text });
                        errdefer self.gpa.free(entry);
                        try out.append(self.gpa, entry);
                    }
                    first_row = false;
                }
            }

            // A turn with nothing in it yet — the reply that has not started —
            // still gets a row, so the cursor has somewhere to be.
            if (first_row) {
                const entry = try std.fmt.allocPrint(self.gpa, "{s}", .{mark});
                errdefer self.gpa.free(entry);
                try out.append(self.gpa, entry);
            }

            if (is_selected) {
                const position = wrappedPosition(raw, self.doc.cursor, inner);
                if (content_start) |start| {
                    cursor_row.* = start + position.row;
                    cursor_col.* = @min(gutter + position.col, if (width > 0) width - 1 else 0);
                } else {
                    cursor_row.* = out.items.len - 1;
                    cursor_col.* = gutter;
                }
            }
        }
    }

    /// A ```pikchr fence's cells: rendered and transmitted the first time it is
    /// seen, and answered from the cache after — the render runs two commands,
    /// so a frame must never pay for it twice.
    fn resolveDiagram(ctx: *anyopaque, allocator: std.mem.Allocator, source: []const u8) ?markup.Diagrams.Diagram {
        const self: *Tui = @ptrCast(@alignCast(ctx));
        if (self.pictures.get(source)) |cached| return if (cached.id == 0) null else cached;
        const picture = self.paintDiagram(allocator, source) orelse {
            self.remember(source, .{ .id = 0, .cols = 0, .rows = 0 });
            return null;
        };
        self.remember(source, picture);
        return picture;
    }

    fn remember(self: *Tui, source: []const u8, picture: markup.Diagrams.Diagram) void {
        const key = self.gpa.dupe(u8, source) catch return;
        self.pictures.put(key, picture) catch self.gpa.free(key);
    }

    /// Runs the pikchr and rasterizer commands and sends the PNG to the
    /// terminal with a virtual placement, so the placeholder rows can show it.
    fn paintDiagram(self: *Tui, allocator: std.mem.Allocator, source: []const u8) ?markup.Diagrams.Diagram {
        const tools = self.diagrams orelse return null;
        const image = (tools.render(self.io, allocator, source) catch return null) orelse return null;
        defer image.deinit(allocator);
        const cell = self.cellSize();
        const wide = @max(1, @as(usize, @intFromFloat(image.width / cell.width)));
        const tall = @max(1, @as(usize, @intFromFloat(image.height / cell.height)));
        // The picture cannot be wider than the transcript it sits in; kitty
        // fits it to the box, so clamping the columns is enough.
        const cols = @min(wide, @max(self.cols -| 4, 1));
        const id = imageId(source);
        graphics.transmit(allocator, id, image.png, cols, tall) catch return null;
        return .{ .id = id, .cols = cols, .rows = tall };
    }

    /// One cell of the terminal in pixels, from its window and the cells it
    /// holds; an assumed cell when the terminal reports no pixels.
    const Cell = struct { width: f32, height: f32 };
    fn cellSize(self: *Tui) Cell {
        if (kitty.pixels()) |pixels| {
            const cols: f32 = @floatFromInt(@max(self.cols, 1));
            const rows: f32 = @floatFromInt(@max(self.rows, 1));
            return .{
                .width = @as(f32, @floatFromInt(pixels.cols)) / cols,
                .height = @as(f32, @floatFromInt(pixels.rows)) / rows,
            };
        }
        return .{ .width = 9, .height = 18 };
    }
};

/// The id a fence's picture is transmitted under, and the one its placeholder
/// cells name: a hash of the fence's text, kept in 24 bits and never zero.
fn imageId(source: []const u8) u32 {
    const hash = std.hash.Wyhash.hash(0, source);
    const id: u32 = @truncate(hash & 0xFFFFFF);
    return if (id == 0) 1 else id;
}

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
fn wrappedPosition(text: []const u8, index: usize, width: usize) struct { line: usize, row: usize, col: usize } {
    var at: usize = 0;
    var line: usize = 0;
    var at_row: usize = 0;
    var cells: usize = 0;
    const limit = @min(index, text.len);
    while (at < limit) {
        if (text[at] == '\n') {
            line += 1;
            at_row = 0;
            cells = 0;
            at += 1;
            continue;
        }
        const here = kitty.clusterWidth(text, at);
        if (cells != 0 and cells + here > width) {
            at_row += 1;
            cells = 0;
        }
        cells += here;
        at = kitty.nextGrapheme(text, at);
    }
    return .{ .line = line, .row = at_row, .col = cells };
}

/// The `:keys` sheet: every section with its keys padded into a column, then
/// the commands. Built from the tables above rather than written out again, so
/// a binding that changes is a binding that reads right here.
fn sheetText(gpa: std.mem.Allocator) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    for (sections, 0..) |section, index| {
        if (index != 0) try text.append(gpa, '\n');
        try text.appendSlice(gpa, section.name);
        try text.append(gpa, '\n');
        const column = keysColumn(section.rows);
        for (section.rows) |binding| {
            try text.appendSlice(gpa, binding.keys);
            try text.appendNTimes(gpa, ' ', column - row.visibleWidth(binding.keys) + 2);
            try text.appendSlice(gpa, binding.what);
            try text.append(gpa, '\n');
        }
    }

    try text.append(gpa, '\n');
    try text.appendSlice(gpa, "commands\n");
    var column: usize = 0;
    for (commands) |command| column = @max(column, row.visibleWidth(command.name));
    for (commands) |command| {
        try text.appendSlice(gpa, command.name);
        try text.appendNTimes(gpa, ' ', column - row.visibleWidth(command.name) + 2);
        try text.appendSlice(gpa, command.what);
        try text.append(gpa, '\n');
    }
    return text.toOwnedSlice(gpa);
}

/// The widest key string of a column, in cells.
fn keysColumn(rows: []const Binding) usize {
    var column: usize = 0;
    for (rows) |binding| column = @max(column, row.visibleWidth(binding.keys));
    return column;
}

/// Frees the rows of a list this file built, and the list. `deinit` takes the
/// list by value, which would leave the caller's copy pointing at freed memory;
/// `clearAndFree` is the one that goes through the pointer.
fn freeRows(gpa: std.mem.Allocator, rows: *std.ArrayList([]u8)) void {
    for (rows.items) |text| gpa.free(text);
    rows.clearAndFree(gpa);
}

/// The host a Python `run1` call reaches: a method name and its argument,
/// answered with JSON the shim frees. `context` is the `*Tui` `setHost` was
/// given; a method that failed answers nothing.
fn hostCall(context: ?*anyopaque, method: [*:0]const u8, argument: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const self: *Tui = @ptrCast(@alignCast(context.?));
    return self.host(std.mem.span(method), std.mem.span(argument)) catch null;
}

/// The harness's system prompt, as an owned string.
fn systemPromptText(allocator: std.mem.Allocator) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try run1.system_prompt.systemPrompt(&out.writer);
    return allocator.dupe(u8, out.written());
}

/// One named string argument of a tool call, read out of the JSON it was given.
fn argumentOf(gpa: std.mem.Allocator, arguments: []const u8, name: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, arguments, .{}) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const value = object.get(name) orelse return null;
    const text = switch (value) {
        .string => |string| string,
        else => return null,
    };
    return gpa.dupe(u8, text) catch null;
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
