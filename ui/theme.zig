//! The styles the UI draws with, named rather than written at the call site.
//! omp's TUI keeps a theme for the same reason: a component says what a thing
//! *is* — the status bar, a selection, a sent turn — and one file decides how
//! that looks, so restyling is not a hunt through the drawing code.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const reset = "\x1b[0m";
/// The status bar: reverse video, so it reads as a surface rather than a line.
pub const bar = "\x1b[7m";
/// What a motion selected.
pub const selection = "\x1b[7m";
pub const dim = "\x1b[2m";
pub const accent = "\x1b[36m";
pub const bold = "\x1b[1m";
pub const warning = "\x1b[33m";
pub const italic = "\x1b[3m";
pub const underline = "\x1b[4m";
pub const strike = "\x1b[9m";
/// A code span or block: the terminal's "reverse" is a poor fit in a transcript,
/// so code is the accent colour, which theme has a name for.
pub const code = "\x1b[36m";

/// `text` in `style`.
pub fn paint(allocator: Allocator, style: []const u8, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ style, text, reset });
}

/// `text` with `[start, end)` — byte offsets into it — drawn as the selection.
pub fn highlight(allocator: Allocator, text: []const u8, start: usize, end: usize) ![]u8 {
    const from = @min(start, text.len);
    const to = @min(end, text.len);
    if (to <= from) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{
        text[0..from],
        selection,
        text[from..to],
        reset,
        text[to..],
    });
}
