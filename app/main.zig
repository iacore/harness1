const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");

/// Prints the harness system prompt: the full feature vocabulary with the
/// implemented features marked. It is printed rather than assembled, so the same
/// writer that draws it can be the one that sends it to the API.
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &buffer);
    try run1.turns.systemPrompt(&out.interface);
    try out.flush();
}
