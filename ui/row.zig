//! Rows: the strings a component draws, and the width-aware operations on them.
//!
//! The shape is omp's TUI: a component returns rows of text, styling travels
//! inside them as SGR escapes, and one measurement — cells, not bytes —
//! decides where anything sits. So every operation here counts cells and steps
//! by grapheme, and an escape sequence costs nothing and is never split.
//!
//! `wrap` is what the editor draws with: it cuts a turn's text into rows of at
//! most `width` cells, which is why no line ever reaches the terminal's own
//! wrapping — the frame decides where the line ends, not the terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const kitty = @import("kitty.zig");

/// The cells a row occupies, ignoring styling escapes.
pub fn visibleWidth(row: []const u8) usize {
    var cells: usize = 0;
    var at: usize = 0;
    while (at < row.len) {
        if (row[at] == 0x1b) {
            at = skipEscape(row, at);
            continue;
        }
        cells += kitty.clusterWidth(row, at);
        at = kitty.nextGrapheme(row, at);
    }
    return cells;
}

/// The byte after the escape sequence starting at `at` — `ESC [ … final`, or
/// just past the `ESC` when it is not a control sequence.
fn skipEscape(row: []const u8, at: usize) usize {
    var i = at + 1;
    if (i >= row.len or row[i] != '[') return i;
    i += 1;
    while (i < row.len and !(row[i] >= 0x40 and row[i] <= 0x7e)) i += 1;
    return @min(i + 1, row.len);
}

/// `row` cut to at most `width` cells, keeping the escapes that fall inside.
pub fn truncate(allocator: Allocator, row: []const u8, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cells: usize = 0;
    var at: usize = 0;
    while (at < row.len) {
        if (row[at] == 0x1b) {
            const next = skipEscape(row, at);
            try out.appendSlice(allocator, row[at..next]);
            at = next;
            continue;
        }
        const here = kitty.clusterWidth(row, at);
        if (cells + here > width) break;
        const next = kitty.nextGrapheme(row, at);
        try out.appendSlice(allocator, row[at..next]);
        cells += here;
        at = next;
    }
    return out.toOwnedSlice(allocator);
}

/// `row` split into rows of at most `width` cells, escapes kept in place and no
/// cluster split across rows. An empty row yields one empty row.
pub fn wrap(allocator: Allocator, row: []const u8, width: usize, out: *std.ArrayList([]u8)) !void {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    var cells: usize = 0;
    var at: usize = 0;
    while (at < row.len) {
        if (row[at] == 0x1b) {
            const next = skipEscape(row, at);
            try line.appendSlice(allocator, row[at..next]);
            at = next;
            continue;
        }
        const here = kitty.clusterWidth(row, at);
        if (cells != 0 and cells + here > width) {
            try out.append(allocator, try line.toOwnedSlice(allocator));
            line = .empty;
            cells = 0;
        }
        const next = kitty.nextGrapheme(row, at);
        try line.appendSlice(allocator, row[at..next]);
        cells += here;
        at = next;
    }
    try out.append(allocator, try line.toOwnedSlice(allocator));
}

test "cells, not bytes, and escapes are free" {
    try std.testing.expectEqual(@as(usize, 3), visibleWidth("abc"));
    try std.testing.expectEqual(@as(usize, 3), visibleWidth("\x1b[7mabc\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 6), visibleWidth("中文abc"));
    try std.testing.expectEqual(@as(usize, 4), visibleWidth("café"));
}

test "truncate keeps the escapes inside the width it keeps" {
    const allocator = std.testing.allocator;
    const cut = try truncate(allocator, "\x1b[7mabcdef\x1b[0m", 3);
    defer allocator.free(cut);
    try std.testing.expectEqualStrings("\x1b[7mabc", cut);
    try std.testing.expectEqual(@as(usize, 3), visibleWidth(cut));

    const whole = try truncate(allocator, "中文", 3);
    defer allocator.free(whole);
    try std.testing.expectEqualStrings("中", whole);
}

test "wrap cuts on cells and never splits a cluster" {
    const allocator = std.testing.allocator;
    var rows: std.ArrayList([]u8) = .empty;
    defer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }

    try wrap(allocator, "abcd", 2, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("ab", rows.items[0]);
    try std.testing.expectEqualStrings("cd", rows.items[1]);

    for (rows.items) |row| allocator.free(row);
    rows.clearRetainingCapacity();

    // A wide character that would not fit starts the next row.
    try wrap(allocator, "中文", 3, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("中", rows.items[0]);
    try std.testing.expectEqualStrings("文", rows.items[1]);
}
