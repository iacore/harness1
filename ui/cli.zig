//! The CLI mode: print the harness system prompt and stop. It is what a pipe
//! gets, and what `--print` asks for on a terminal.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");

pub fn run(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(init.io, &buffer);
    try run1.system_prompt.systemPrompt(&out.interface);
    try out.flush();
}