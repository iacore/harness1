//! run1's scripting layer: CPython, embedded in this process but never owning
//! the terminal. A line is evaluated and its output captured, and the namespace
//! persists, so a name set on one line is there on the next. `add_turn` is the
//! step the prompt calls when it is submitted; the Python side of it lives in
//! `python_shim.c`.

const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn run1_python_eval(code: [*:0]const u8) [*:0]u8;
extern fn run1_python_add_turn(text: [*:0]const u8) [*:0]u8;
extern fn run1_python_free(text: [*:0]u8) void;

/// Evaluates one line and returns its captured output, as an owned copy.
pub fn eval(allocator: Allocator, code: []const u8) ![]u8 {
    const zeroed = try allocator.dupeSentinel(u8, code, 0);
    defer allocator.free(zeroed);
    return takeCaptured(allocator, run1_python_eval(zeroed.ptr));
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