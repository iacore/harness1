//! Sends one prompt to the DeepSeek Chat Completions endpoint and prints the
//! reply. A scratch program for poking at the client in
//! src/remote/deepseek.zig, not part of the library.
//!
//! Run:
//!   zig build --build-file ./build.research.zig deepseek_playground
//!
//! Type check only:
//!   zig build-obj --dep run1 -Mroot=research/deepseek_playground.zig -Mrun1=src/root.zig -fno-emit-bin

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const deepseek = run1.deepseek;
const keys = run1.keys;
const debug = run1.debug;

const prompt = "Hello";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;

    // The key comes from the process arena, which outlives the client that
    // borrows it.
    const api_key = try keys.apiKey(init.arena.allocator(), io, debug.writer(out), init.environ_map, keys.Provider.deepseek) orelse {
        try out.writeAll("no DeepSeek key: set DEEPSEEK_API_KEY, or sign in to the `deepseek` provider of omp\n");
        try out.flush();
        return error.ApiKeyRequired;
    };

    var client = try deepseek.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    const messages = [_]deepseek.chat.Message{
        .{ .user = .{ .content = deepseek.chat.text(prompt) } },
    };
    const result = try deepseek.chat.send(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
        // The default is thinking mode, whose answer arrives after a chain of
        // thought; the playground wants the completion itself.
        .thinking = .disabled,
    });

    var completion = switch (result) {
        .ok => |parsed| parsed,
        .err => |failure| {
            try out.writeAll("request failed: ");
            try failure.format(out);
            try out.writeByte('\n');
            try out.flush();
            return error.RequestFailed;
        },
    };
    defer completion.deinit();

    const message = completion.value.message();
    try out.print("prompt: {s}\n", .{prompt});
    try out.print("model:  {s}\n", .{completion.value.model});
    try out.print("reply:  {s}\n", .{message.content orelse ""});
    if (message.reasoning_content) |reasoning| {
        // Present but empty is a turn the model thought nothing on, which is
        // not the same as one with a chain of thought to show.
        if (reasoning.len != 0) try out.print("reason: {s}\n", .{reasoning});
    }
    if (completion.value.usage) |usage| {
        try out.print("tokens: {d} prompt + {d} completion = {d}\n", .{
            usage.prompt_tokens, usage.completion_tokens, usage.total_tokens,
        });
    }
    try out.flush();
}
