//! The model behind an assistant turn: LithosAI's chat endpoint, streamed, so
//! the turn fills in as the answer arrives rather than appearing in one piece.
//!
//! The message list is the revision's path — the turns as they were sent and
//! answered — and the model and the thinking effort are named here, because
//! they are what the turn is tagged with.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const lithos = run1.lithos;
const keys = run1.keys;
const debug = run1.debug;

/// The default: DeepSeek V4.1 Flash on LithosAI.
pub const default_model = "deepseek-ai/DeepSeek-V4.1-Flash";
/// Thinking is asked for at its lowest named effort. The roster notes what each
/// model does with an effort; this is what the turn's tag records we asked for.
pub const default_effort: lithos.chat.NamedEffort = .low;

pub const Role = enum { user, assistant };

pub const Turn = struct {
    role: Role,
    text: []const u8,
};

/// Where a streamed chunk goes. A function pointer with its own context, so
/// this file knows nothing about what draws it.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) void,

    pub fn emit(self: Sink, chunk: []const u8) void {
        self.write(self.context, chunk);
    }
};

/// Streams one reply to `turns`, handing each chunk to `sink` as it arrives.
/// A failure the API or the key produces is written to `reason` — the caller
/// shows it, because a silent empty turn would read as the model saying
/// nothing.
pub fn reply(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    logger: anytype,
    turns: []const Turn,
    reason: *std.ArrayList(u8),
    sink: Sink,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const api_key = try keys.apiKey(arena, io, logger, environ_map, keys.Provider.lithosai) orelse {
        try reason.appendSlice(gpa, "no LithosAI key: set LITHOSAI_API_KEY, or sign in to the `lithosai` provider of omp");
        return error.NoKey;
    };

    var messages: std.ArrayList(lithos.chat.Message) = .empty;
    for (turns) |turn| {
        try messages.append(arena, switch (turn.role) {
            .user => .{ .user = .{ .content = lithos.chat.text(turn.text) } },
            .assistant => .{ .assistant = .{ .content = .{ .text = turn.text } } },
        });
    }

    var client = try lithos.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    var received = switch (try lithos.chat.sendStream(&client, &.{
        .model = default_model,
        .messages = messages.items,
        .reasoning_effort = .{ .named = default_effort },
    })) {
        .ok => |stream| stream,
        .err => |failure| {
            var text: Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            try failure.format(&text.writer);
            try reason.appendSlice(gpa, text.written());
            return error.RequestFailed;
        },
    };
    defer received.deinit();

    // The chunk arena is reset per chunk: a delta is text the caller has
    // already taken, and nothing else in it is kept.
    var chunk_state = std.heap.ArenaAllocator.init(gpa);
    defer chunk_state.deinit();
    while (try received.recv(chunk_state.allocator())) |chunk| {
        for (chunk.choices) |choice| {
            const content = choice.delta.content orelse continue;
            if (content.len != 0) sink.emit(content);
        }
        _ = chunk_state.reset(.retain_capacity);
    }
}
