//! Prints every delta of a streamed LithosAI reply, to see which fields a model
//! fills in and when — content, the chain of thought, or neither for a while.
//!
//! A scratch program, not part of the library: it needs a key and a network.
//!
//!   zig build --build-file ./build.research.zig model_probe [-- <model> <effort>]

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const ipython_model = @import("model");
const lithos = run1.lithos;
const keys = run1.keys;
const debug = run1.debug;

/// Collects what `ui/model.zig` streams, so the probe prints it the same way
/// the TUI would draw it.
const Collected = struct {
    text: std.ArrayList(u8) = .empty,

    fn sink(self: *Collected) ipython_model.Sink {
        return .{ .context = self, .write = write };
    }

    fn write(context: *anyopaque, chunk: []const u8) void {
        const self: *Collected = @ptrCast(@alignCast(context));
        self.text.appendSlice(std.heap.page_allocator, chunk) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const err_out = &stderr_file.interface;

    var model_id: []const u8 = "deepseek-ai/DeepSeek-V4.1-Flash";
    var effort: lithos.chat.NamedEffort = .low;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip();
    if (args.next()) |given| model_id = given;
    if (args.next()) |given| {
        effort = std.meta.stringToEnum(lithos.chat.NamedEffort, given) orelse effort;
    }

    const arena = init.arena.allocator();
    const api_key = try keys.apiKey(arena, io, debug.writer(err_out), init.environ_map, keys.Provider.lithosai) orelse {
        try err_out.writeAll("no LithosAI key\n");
        try err_out.flush();
        return error.ApiKeyRequired;
    };

    const messages = [_]lithos.chat.Message{
        .{ .user = .{ .content = lithos.chat.text("Count from one to five, one number per line.") } },
    };

    var client = try lithos.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    try out.print("model {s}  effort {s}\n", .{ model_id, @tagName(effort) });
    var received = switch (try lithos.chat.sendStream(&client, &.{
        .model = model_id,
        .messages = &messages,
        .reasoning_effort = .{ .named = effort },
    })) {
        .ok => |stream| stream,
        .err => |failure| {
            try out.writeAll("failure: ");
            try failure.format(out);
            try out.writeByte('\n');
            try out.flush();
            return;
        },
    };
    defer received.deinit();

    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    var deltas: usize = 0;
    while (try received.recv(state.allocator())) |chunk| {
        for (chunk.choices) |choice| {
            deltas += 1;
            try out.print("{d}: content={?s} reasoning={?s} finish={?s}\n", .{
                deltas,
                choice.delta.content,
                choice.delta.reasoning_content,
                choice.finish_reason,
            });
        }
        _ = state.reset(.retain_capacity);
    }
    try out.print("{d} deltas\n", .{deltas});
    try out.flush();

    // The same prompt through `ui/model.zig`, which is what the TUI calls.
    var collected: Collected = .{};
    defer collected.text.deinit(std.heap.page_allocator);
    var reason: std.ArrayList(u8) = .empty;
    defer reason.deinit(gpa);
    const turns = [_]ipython_model.Turn{
        .{ .role = .user, .text = "Count from one to five, one number per line." },
    };
    ipython_model.reply(gpa, io, init.environ_map, debug.writer(err_out), &turns, &reason, collected.sink()) catch {
        try out.print("ui/model failed: {s}\n", .{reason.items});
        try out.flush();
        return;
    };
    try out.print("ui/model reply: {d} bytes\n{s}\n", .{ collected.text.items.len, collected.text.items });
    try out.flush();
}
