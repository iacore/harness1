//! run1's scripting layer: an IPython shell embedded in this process, never
//! owning the terminal. A line is run through the shell and its output
//! captured; the shell keeps the state, the history and the completion, so the
//! command line behaves as IPython's does. `add_turn` is the step run1's own
//! prompt calls when it is submitted — both live in `python_shim.c`.

const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn run1_python_run(code: [*:0]const u8) [*:0]u8;
extern fn run1_python_complete(line: [*:0]const u8, cursor: c_int) [*:0]u8;
extern fn run1_python_history(offset: c_int) [*:0]u8;
extern fn run1_python_fish(command: [*:0]const u8) [*:0]u8;
extern fn run1_python_add_turn(text: [*:0]const u8) [*:0]u8;
extern fn run1_python_free(text: [*:0]u8) void;

/// Runs one line in the shell and returns what it printed, as an owned copy.
pub fn run(allocator: Allocator, code: []const u8) ![]u8 {
    const zeroed = try allocator.dupeSentinel(u8, code, 0);
    defer allocator.free(zeroed);
    return takeCaptured(allocator, run1_python_run(zeroed.ptr));
}

/// The completions for `line` at `cursor`, one per line, as an owned copy.
pub fn complete(allocator: Allocator, line: []const u8, cursor: usize) ![]u8 {
    const zeroed = try allocator.dupeSentinel(u8, line, 0);
    defer allocator.free(zeroed);
    return takeCaptured(allocator, run1_python_complete(zeroed.ptr, @intCast(cursor)));
}

/// The input `offset` steps back in the shell's history — one is the last line
/// — or an empty copy when there is none.
pub fn history(allocator: Allocator, offset: usize) ![]u8 {
    return takeCaptured(allocator, run1_python_history(@intCast(offset)));
}

/// Runs `command` in fish and returns what it printed, as an owned copy.
pub fn fish(allocator: Allocator, command: []const u8) ![]u8 {
    const zeroed = try allocator.dupeSentinel(u8, command, 0);
    defer allocator.free(zeroed);
    return takeCaptured(allocator, run1_python_fish(zeroed.ptr));
}

/// Runs the script's `add_turn` step on `text` and returns its captured output,
/// as an owned copy.
pub fn addTurn(allocator: Allocator, text: []const u8) ![]u8 {
    const zeroed = try allocator.dupeSentinel(u8, text, 0);
    defer allocator.free(zeroed);
    return takeCaptured(allocator, run1_python_add_turn(zeroed.ptr));
}

fn takeCaptured(allocator: Allocator, captured: [*:0]u8) ![]u8 {
    defer run1_python_free(captured);
    return allocator.dupe(u8, std.mem.span(captured));
}
