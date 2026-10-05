const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");

/// Emits the harness system prompt: the full feature vocabulary with the
/// implemented features marked. The agent loop that follows reads it from here.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const prompt = try run1.omp_features.systemPrompt(arena);
    const text = try prompt.flatten(arena);
    try Io.File.stdout().writeStreamingAll(init.io, text);
}