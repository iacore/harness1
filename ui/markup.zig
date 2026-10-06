//! Turn text, rendered: Djot in, rows out. A turn's reply is written in Djot
//! (`research/rich-text.dj`), and this is the one place that turns it into the
//! rows the TUI draws — headings bold, emphasis italic, a `---` into a rule, a
//! list into bullets, and a ```pikchr fence into a picture.
//!
//! A picture is the one thing that is not cells: it is transmitted to the
//! terminal (`graphics.zig`) and referred to by placeholder rows, so it scrolls
//! with the text. When no pikchr is installed the fence is drawn as code, which
//! is what an unknown language does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const djot = @import("djot");
const row = @import("row.zig");
const theme = @import("theme.zig");
const graphics = @import("graphics.zig");

/// Where a ```pikchr block's picture comes from — the caller's, because only it
/// knows the terminal and holds the cache. `null` back means "show the source".
pub const Diagrams = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, allocator: Allocator, source: []const u8) ?Diagram,

    pub const Diagram = struct { id: u32, cols: usize, rows: usize };
};

/// Renders `text` to owned rows no wider than `width` cells, the styling inside
/// them as SGR. The caller frees every row and the list.
pub fn render(allocator: Allocator, text: []const u8, width: usize, diagrams: ?Diagrams) !std.ArrayList([]u8) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const document = djot.parse.parse(arena.allocator(), text, .{}) catch {
        // Not Djot: draw it as it stands rather than as a parse error.
        return plain(allocator, text, width);
    };

    var painter: Painter = .{
        .gpa = allocator,
        .width = if (width > 0) width else 1,
        .diagrams = diagrams,
    };
    errdefer painter.deinit();
    try painter.blocks(document);
    // The rows are the result; the line buffer they were built in is not.
    painter.line.deinit(allocator);
    return painter.rows;
}

/// A line at a time, when nothing about it parsed.
fn plain(allocator: Allocator, text: []const u8, width: usize) !std.ArrayList([]u8) {
    var painter: Painter = .{ .gpa = allocator, .width = if (width > 0) width else 1 };
    errdefer painter.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try painter.line.appendSlice(allocator, line);
        try painter.flush();
    }
    if (painter.rows.items.len == 0) try painter.rows.append(allocator, try allocator.dupe(u8, ""));
    painter.line.deinit(allocator);
    return painter.rows;
}

const Painter = struct {
    gpa: Allocator,
    width: usize,
    diagrams: ?Diagrams = null,
    rows: std.ArrayList([]u8) = .empty,
    /// The logical line being built, styled as SGR, wrapped only at `flush`.
    line: std.ArrayList(u8) = .empty,
    /// What the first row of the line starts with — a bullet, a heading's `#`.
    prefix: []const u8 = "",
    /// The style to reopen after a wrap, so a wrapped emphasis stays emphasised.
    open: []const u8 = "",

    fn deinit(self: *Painter) void {
        for (self.rows.items) |line| self.gpa.free(line);
        self.rows.deinit(self.gpa);
        self.line.deinit(self.gpa);
    }

    fn text(self: *Painter, bytes: []const u8) !void {
        try self.line.appendSlice(self.gpa, bytes);
    }

    /// `n` spaces, for indenting a wrapped line under its bullet.
    fn spaces(self: *Painter, n: usize) ![]u8 {
        const bytes = try self.gpa.alloc(u8, n);
        @memset(bytes, ' ');
        return bytes;
    }

    fn styled(self: *Painter, style: []const u8, bytes: []const u8) !void {
        if (style.len == 0) return self.text(bytes);
        const painted = try theme.paint(self.gpa, style, bytes);
        defer self.gpa.free(painted);
        try self.line.appendSlice(self.gpa, painted);
    }

    /// Ends the line: wraps it to the width and keeps the rows, the prefix on
    /// the first.
    fn flush(self: *Painter) !void {
        var pieces: std.ArrayList([]u8) = .empty;
        defer {
            for (pieces.items) |piece| self.gpa.free(piece);
            pieces.deinit(self.gpa);
        }
        try row.wrap(self.gpa, self.line.items, self.width, &pieces);
        for (pieces.items, 0..) |piece, i| {
            const lead = if (i == 0) self.prefix else "";
            const entry = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ lead, piece });
            errdefer self.gpa.free(entry);
            try self.rows.append(self.gpa, entry);
        }
        self.line.clearRetainingCapacity();
        self.prefix = "";
    }

    /// A blank row, for the space between blocks.
    fn blank(self: *Painter) !void {
        if (self.rows.items.len != 0) try self.rows.append(self.gpa, try self.gpa.dupe(u8, ""));
    }

    fn blocks(self: *Painter, node: *djot.ast.Node) anyerror!void {
        for (node.children.items) |child| try self.block(child);
    }

    fn block(self: *Painter, node: *djot.ast.Node) anyerror!void {
        const tag = node.tag;
        if (std.mem.eql(u8, tag, "doc") or std.mem.eql(u8, tag, "section") or
            std.mem.eql(u8, tag, "container") or std.mem.eql(u8, tag, "div"))
        {
            try self.blocks(node);
        } else if (std.mem.eql(u8, tag, "para")) {
            try self.inlineChildren(node);
            try self.flush();
        } else if (std.mem.eql(u8, tag, "heading")) {
            const level = levelOf(node);
            const marks = "######";
            const heading_prefix = try std.fmt.allocPrint(self.gpa, "{s} ", .{marks[0..level]});
            defer self.gpa.free(heading_prefix);
            self.prefix = heading_prefix;
            try self.inlineChildren(node);
            // Paint the whole line bold, prefix included.
            const painted = try theme.paint(self.gpa, theme.bold, self.line.items);
            defer self.gpa.free(painted);
            self.line.clearRetainingCapacity();
            try self.line.appendSlice(self.gpa, painted);
            self.prefix = heading_prefix;
            try self.flush();
            try self.blank();
        } else if (std.mem.eql(u8, tag, "thematic_break")) {
            var rule: std.ArrayList(u8) = .empty;
            defer rule.deinit(self.gpa);
            var tick: usize = 0;
            while (tick < self.width) : (tick += 1) try rule.appendSlice(self.gpa, "\u{2500}");
            try self.styled(theme.dim, rule.items);
            try self.flush();
            try self.blank();
        } else if (std.mem.eql(u8, tag, "code_block") or std.mem.eql(u8, tag, "raw_block")) {
            try self.codeBlock(node);
        } else if (std.mem.eql(u8, tag, "block_quote")) {
            try self.quoted(node);
        } else if (isList(tag)) {
            try self.list(node);
        } else if (std.mem.eql(u8, tag, "definition_list")) {
            try self.definitionList(node);
        } else if (std.mem.eql(u8, tag, "table")) {
            try self.table(node);
        } else if (std.mem.eql(u8, tag, "reference") or std.mem.eql(u8, tag, "footnote") or
            std.mem.eql(u8, tag, "caption"))
        {
            // Nothing to draw: a definition, a note kept for a reference, a
            // table's caption already shown.
        } else {
            // An unknown block: draw its content rather than nothing.
            try self.blocks(node);
        }
    }

    fn codeBlock(self: *Painter, node: *djot.ast.Node) anyerror!void {
        const source = std.mem.trimEnd(u8, node.text, "\n");
        if (std.mem.eql(u8, node.getData("lang") orelse "", "pikchr")) {
            if (self.diagram(source)) return;
        }
        var lines = std.mem.splitScalar(u8, source, '\n');
        var any = false;
        while (lines.next()) |line| {
            if (line.len == 0 and !any) continue;
            any = true;
            self.prefix = "│ ";
            try self.styled(theme.code, line);
            try self.flush();
        }
        if (!any) {
            self.prefix = "│ ";
            try self.flush();
        }
        try self.blank();
    }

    /// Draws `source` as a picture via the caller, or reports that it could not.
    fn diagram(self: *Painter, source: []const u8) bool {
        const diagrams = self.diagrams orelse return false;
        const picture = diagrams.resolve(diagrams.ctx, self.gpa, source) orelse return false;
        graphics.placeholders(self.gpa, picture.id, picture.cols, picture.rows, &self.rows) catch return false;
        return true;
    }

    fn quoted(self: *Painter, node: *djot.ast.Node) anyerror!void {
        var inner: Painter = .{ .gpa = self.gpa, .width = self.width -| 2, .diagrams = self.diagrams };
        defer inner.deinit();
        try inner.blocks(node);
        for (inner.rows.items) |line| {
            const painted = try theme.paint(self.gpa, theme.dim, line);
            defer self.gpa.free(painted);
            try self.rows.append(self.gpa, try std.fmt.allocPrint(self.gpa, "│ {s}", .{painted}));
        }
        try self.blank();
    }

    fn list(self: *Painter, node: *djot.ast.Node) anyerror!void {
        var number: usize = std.fmt.parseInt(usize, node.getData("start") orelse "1", 10) catch 1;
        for (node.children.items) |item| {
            const marker = try self.bullet(node.tag, item, number);
            defer self.gpa.free(marker);
            number += 1;

            var inner: Painter = .{ .gpa = self.gpa, .width = self.width -| row.visibleWidth(marker), .diagrams = self.diagrams };
            defer inner.deinit();
            inner.prefix = marker;
            try inner.blocks(item);
            for (inner.rows.items, 0..) |line, i| {
                if (i == 0) {
                    try self.rows.append(self.gpa, try self.gpa.dupe(u8, line));
                } else {
                    const pad = try self.spaces(row.visibleWidth(marker));
                    defer self.gpa.free(pad);
                    try self.rows.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ pad, line }));
                }
            }
        }
        try self.blank();
    }

    fn bullet(self: *Painter, list_tag: []const u8, item: *djot.ast.Node, number: usize) ![]u8 {
        const width = row.visibleWidth(list_tag);
        _ = width;
        if (std.mem.eql(u8, list_tag, "ordered_list")) {
            return std.fmt.allocPrint(self.gpa, "{d}. ", .{number});
        }
        if (std.mem.eql(u8, list_tag, "task_list")) {
            const checked = if (item.getData("checkbox")) |c| std.mem.eql(u8, c, "checked") else false;
            return self.gpa.dupe(u8, if (checked) "\u{2611} " else "\u{2610} ");
        }
        return self.gpa.dupe(u8, "\u{2022} ");
    }

    fn definitionList(self: *Painter, node: *djot.ast.Node) anyerror!void {
        for (node.children.items) |item| {
            for (item.children.items) |part| {
                const prefix = if (std.mem.eql(u8, part.tag, "term")) "" else "  ";
                _ = prefix;
                var inner: Painter = .{ .gpa = self.gpa, .width = self.width -| 2, .diagrams = self.diagrams };
                defer inner.deinit();
                if (std.mem.eql(u8, part.tag, "term")) {
                    try inner.inlineChildren(part);
                } else {
                    try inner.blocks(part);
                }
                for (inner.rows.items) |line| {
                    try self.rows.append(self.gpa, try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ if (std.mem.eql(u8, part.tag, "term")) "" else "  ", line }));
                }
            }
        }
        try self.blank();
    }

    fn table(self: *Painter, node: *djot.ast.Node) anyerror!void {
        for (node.children.items) |entry| {
            if (!std.mem.eql(u8, entry.tag, "row")) continue;
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(self.gpa);
            try line.appendSlice(self.gpa, "| ");
            for (entry.children.items, 0..) |cell, i| {
                if (i != 0) try line.appendSlice(self.gpa, " | ");
                var inner: Painter = .{ .gpa = self.gpa, .width = self.width, .diagrams = self.diagrams };
                defer inner.deinit();
                try inner.inlineChildren(cell);
                try line.appendSlice(self.gpa, inner.line.items);
            }
            try line.appendSlice(self.gpa, " |");
            try self.line.appendSlice(self.gpa, line.items);
            try self.flush();
        }
        try self.blank();
    }

    /// Walks a node's inline children into the line.
    fn inlineChildren(self: *Painter, node: *djot.ast.Node) anyerror!void {
        for (node.children.items) |child| try self.drawInline(child);
    }

    fn drawInline(self: *Painter, node: *djot.ast.Node) anyerror!void {
        const tag = node.tag;
        if (std.mem.eql(u8, tag, "str") or std.mem.eql(u8, tag, "verbatim") or
            std.mem.eql(u8, tag, "raw_inline") or std.mem.eql(u8, tag, "inline_math") or
            std.mem.eql(u8, tag, "display_math") or std.mem.eql(u8, tag, "smart_punctuation"))
        {
            const style = if (std.mem.eql(u8, tag, "verbatim")) theme.code else "";
            try self.styled(style, node.text);
        } else if (std.mem.eql(u8, tag, "soft_break")) {
            try self.text(" ");
        } else if (std.mem.eql(u8, tag, "hard_break")) {
            try self.flush();
        } else if (std.mem.eql(u8, tag, "non_breaking_space")) {
            try self.text(" ");
        } else if (std.mem.eql(u8, tag, "emph")) {
            try self.wrapped(theme.italic, node);
        } else if (std.mem.eql(u8, tag, "strong")) {
            try self.wrapped(theme.bold, node);
        } else if (std.mem.eql(u8, tag, "mark")) {
            try self.wrapped(theme.selection, node);
        } else if (std.mem.eql(u8, tag, "insert")) {
            try self.wrapped(theme.underline, node);
        } else if (std.mem.eql(u8, tag, "delete")) {
            try self.wrapped(theme.strike, node);
        } else if (std.mem.eql(u8, tag, "superscript") or std.mem.eql(u8, tag, "subscript") or
            std.mem.eql(u8, tag, "span"))
        {
            try self.inlineChildren(node);
        } else if (std.mem.eql(u8, tag, "link")) {
            try self.wrapped(theme.underline, node);
        } else if (std.mem.eql(u8, tag, "image")) {
            // The alt text, in brackets, so a picture with no renderer still
            // says what it was.
            try self.text("[");
            try self.inlineChildren(node);
            try self.text("]");
        } else if (std.mem.eql(u8, tag, "autolink") or std.mem.eql(u8, tag, "url") or
            std.mem.eql(u8, tag, "email") or std.mem.eql(u8, tag, "email_address"))
        {
            try self.wrapped(theme.underline, node);
        } else if (std.mem.eql(u8, tag, "footnote_reference")) {
            try self.styled(theme.dim, "[^]");
        } else if (std.mem.eql(u8, tag, "symb")) {
            try self.text(node.getData("alias") orelse "");
        } else {
            // Anything else: draw its content, or its text if it has none.
            if (node.children.items.len != 0) {
                try self.inlineChildren(node);
            } else if (node.text.len != 0) {
                try self.text(node.text);
            }
        }
    }

    /// Draws a node's inlines with `style` around them, so a wrapped piece
    /// reopens the same style.
    fn wrapped(self: *Painter, style: []const u8, node: *djot.ast.Node) anyerror!void {
        try self.line.appendSlice(self.gpa, style);
        const before = self.line.items.len;
        try self.inlineChildren(node);
        _ = before;
        try self.line.appendSlice(self.gpa, theme.reset);
    }
};

fn isList(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "bullet_list") or std.mem.eql(u8, tag, "ordered_list") or
        std.mem.eql(u8, tag, "task_list") or std.mem.eql(u8, tag, "list");
}

fn levelOf(node: *djot.ast.Node) usize {
    const level = std.fmt.parseInt(usize, node.getData("level") orelse "1", 10) catch 1;
    return @min(@max(level, 1), 6);
}

test "a paragraph is rows at the width given" {
    const allocator = std.testing.allocator;
    var rows = try render(allocator, "hello _world_", 80, null);
    defer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("hello " ++ "\x1b[3m" ++ "world" ++ "\x1b[0m", rows.items[0]);
}

test "a thematic break is a rule as wide as the terminal" {
    const allocator = std.testing.allocator;
    var rows = try render(allocator, "a\n\n---\n\nb", 4, null);
    defer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }
    var saw_rule = false;
    for (rows.items) |line| {
        if (std.mem.indexOf(u8, line, "\u{2500}\u{2500}\u{2500}\u{2500}") != null) saw_rule = true;
    }
    try std.testing.expect(saw_rule);
}

test "a heading opens with its hashes, bold" {
    const allocator = std.testing.allocator;
    var rows = try render(allocator, "## Notes", 40, null);
    defer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }
    try std.testing.expectEqualStrings("\x1b[1m## Notes\x1b[0m", rows.items[0]);
}

test "a bullet is drawn as a bullet" {
    const allocator = std.testing.allocator;
    var rows = try render(allocator, "- one\n- two", 40, null);
    defer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }
    try std.testing.expectEqualStrings("\u{2022} one", rows.items[0]);
    try std.testing.expectEqualStrings("\u{2022} two", rows.items[1]);
}

var dummy: u8 = 0;

fn alwaysDiagram(ctx: *anyopaque, allocator: Allocator, source: []const u8) ?Diagrams.Diagram {
    _ = ctx;
    _ = allocator;
    _ = source;
    return .{ .id = 42, .cols = 3, .rows = 2 };
}

fn neverDiagram(ctx: *anyopaque, allocator: Allocator, source: []const u8) ?Diagrams.Diagram {
    _ = ctx;
    _ = allocator;
    _ = source;
    return null;
}

test "a pikchr fence with a renderer becomes placeholder cells" {
    const allocator = std.testing.allocator;
    var rows = try render(allocator, "```pikchr\nbox\n```", 40, .{ .ctx = @ptrCast(&dummy), .resolve = alwaysDiagram });
    defer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expect(std.mem.startsWith(u8, rows.items[0], "\x1b[38;2;0;0;42m"));
    try std.testing.expectEqual(@as(usize, 3), countCells(rows.items[0]));
}

test "a pikchr fence with no renderer stays code" {
    const allocator = std.testing.allocator;
    var rows = try render(allocator, "```pikchr\nbox\n```", 40, .{ .ctx = @ptrCast(&dummy), .resolve = neverDiagram });
    defer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }
    var saw_source = false;
    for (rows.items) |line| {
        if (std.mem.indexOf(u8, line, "box") != null) saw_source = true;
    }
    try std.testing.expect(saw_source);
}

/// The placeholder cells a row carries, one per cell of the picture.
fn countCells(line: []const u8) usize {
    var count: usize = 0;
    var rest = line;
    while (std.mem.indexOf(u8, rest, graphics.cell)) |at| {
        count += 1;
        rest = rest[at + graphics.cell.len ..];
    }
    return count;
}