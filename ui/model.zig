//! The model behind an assistant turn: LithosAI's chat endpoint, streamed, with
//! the tools this harness declares.
//!
//! One call to `round` is one exchange: the model's text streams to `sink` as it
//! arrives — the chain of thought and the answer told apart — and any tool calls
//! it made are collected for the caller to run. Running them and calling again
//! is the caller's loop, because what a tool does is the caller's business.
//!
//! The model and the thinking effort are named here, because they are what the
//! turn is tagged with.

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

/// What a streamed part is: the chain of thought, or the answer.
pub const Part = enum { reasoning, content };

/// Where a streamed chunk goes. A function pointer with its own context, so
/// this file knows nothing about what draws it, and the two parts are told
/// apart because they are drawn differently and only one of them is the turn.
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, Part, []const u8) void,

    pub fn emit(self: Sink, part: Part, chunk: []const u8) void {
        self.write(self.context, part, chunk);
    }
};

/// A tool the model may call. The schema is JSON Schema text, which is what the
/// endpoint takes: it passes the text through rather than building it here.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

/// The tools this harness declares — what it can actually run, not the whole
/// vocabulary. `fish` is the shell the harness has.
pub const declared = [_]Tool{
    .{
        .name = "fish",
        .description = "Run a command line in a fish shell and return what it printed, with its exit status when it failed.",
        .schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"The fish command line to run.\"}},\"required\":[\"command\"],\"additionalProperties\":false}",
    },
};

/// One call the model made, assembled from the fragments it streamed. Owned by
/// the arena the round was given.
pub const ToolCall = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};

/// Streams one round and collects what the model asked to call. The messages
/// are the caller's: the conversation up to this point, and whatever earlier
/// rounds added.
pub fn round(
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    logger: anytype,
    messages: []const lithos.chat.Message,
    calls: *std.ArrayList(ToolCall),
    arena: std.mem.Allocator,
    reason: *std.ArrayList(u8),
    sink: Sink,
) !void {
    const api_key = try keys.apiKey(arena, io, logger, environ_map, keys.Provider.lithosai) orelse {
        try reason.appendSlice(gpa, "no LithosAI key: set LITHOSAI_API_KEY, or sign in to the `lithosai` provider of omp");
        return error.NoKey;
    };

    var declarations: std.ArrayList(lithos.chat.Tool) = .empty;
    for (declared) |tool| {
        try declarations.append(arena, .{ .function = .{
            .name = tool.name,
            .description = tool.description,
            .parameters = .{ .text = tool.schema },
        } });
    }

    var client = try lithos.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    var received = switch (try lithos.chat.sendStream(&client, &.{
        .model = default_model,
        .messages = messages,
        .tools = declarations.items,
        .tool_choice = .auto,
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

    // The arguments of one call arrive in fragments, so each call is
    // accumulated as it comes: by index, since the id may arrive only once.
    const Pending = struct {
        id: []const u8 = "",
        name: []const u8 = "",
        arguments: std.ArrayList(u8) = .empty,
    };
    var pending: std.ArrayList(Pending) = .empty;

    // The chunk arena is reset per chunk: a delta is text already taken.
    var chunk_state = std.heap.ArenaAllocator.init(gpa);
    defer chunk_state.deinit();
    while (try received.recv(chunk_state.allocator())) |chunk| {
        for (chunk.choices) |choice| {
            if (choice.delta.reasoning_content) |thought| {
                if (thought.len != 0) sink.emit(.reasoning, thought);
            }
            if (choice.delta.content) |content| {
                if (content.len != 0) sink.emit(.content, content);
            }
            for (choice.delta.tool_calls orelse &.{}) |fragment| {
                const index: usize = @intCast(@max(fragment.index orelse 0, 0));
                while (pending.items.len <= index) try pending.append(arena, .{});
                const call = &pending.items[index];
                if (fragment.id) |id| {
                    if (id.len != 0) call.id = try arena.dupe(u8, id);
                }
                if (fragment.function.name) |name| {
                    if (name.len != 0) call.name = try arena.dupe(u8, name);
                }
                if (fragment.function.arguments) |arguments| {
                    if (arguments.len != 0) try call.arguments.appendSlice(arena, arguments);
                }
            }
        }
        _ = chunk_state.reset(.retain_capacity);
    }

    for (pending.items) |call| {
        try calls.append(arena, .{
            .id = call.id,
            .name = call.name,
            .arguments = call.arguments.items,
        });
    }
}
