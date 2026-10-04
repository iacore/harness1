//! Probes the per-model constraints of the LithosAI roster live.
//!
//! A scratch program, not part of the library: it needs a key and a network,
//! so it is neither installed nor built by the default step.
//!
//!   zig build lithos_probe
//!
//! It asks each roster model the same two questions and prints what the API
//! did, because the vendor publishes no per-model metadata and the endpoint
//! does not error out when a model declines a request:
//!
//!   1. Does `reasoning_effort: "none"` actually switch thinking off? The
//!      answer is read from `completion_tokens_details.reasoning_tokens` and
//!      `reasoning_content`, not from the status code.
//!   2. Does the model accept `top_p: 0.5`? Some deployments constrain
//!      sampling to a narrow band and reject the rest with a 400.
//!
//! Findings are recorded in src/remote/lithos_models.md. A model whose
//! behaviour changes will show up here as a changed line; add what you find to
//! that file.

const std = @import("std");
const Io = std.Io;
const harness1 = @import("harness1");
const lithos = harness1.lithos;
const chat = lithos.chat;
const keys = harness1.keys;

/// A prompt short enough to be cheap and reasoning-eliciting enough that a
/// model that ignores the off switch has something to think about.
const prompt = "A farmer has 17 sheep and all but 9 run away. How many are left? Think step by step, then answer.";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const err_out = &stderr_file.interface;

    const arena = init.arena.allocator();
    const api_key = try keys.apiKey(arena, io, init.environ_map, keys.Provider.lithosai) orelse {
        try err_out.writeAll("no LithosAI key: set LITHOSAI_API_KEY, or sign in to the `lithosai` provider of omp\n");
        try err_out.flush();
        return error.ApiKeyRequired;
    };

    var client = try lithos.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    const listed = switch (try lithos.models.list(&client)) {
        .ok => |parsed| parsed,
        .err => |failure| {
            try err_out.writeAll("models request failed: ");
            try failure.format(err_out);
            try err_out.writeByte('\n');
            try err_out.flush();
            return error.RequestFailed;
        },
    };
    defer listed.deinit();

    try out.print("roster: {d} models\n\n", .{listed.value.data.len});

    for (listed.value.data) |model| {
        try out.print("{s}\n", .{model.id});
        try out.writeAll("  none:      ");
        try ask(&client, out, model.id, .{ .named = .none }, null);
        try out.writeAll("  top_p_0.5: ");
        try ask(&client, out, model.id, .{ .named = .none }, 0.5);
        try out.flush();
    }

    // API-wide: the two forms `reasoning_effort` takes, checked on the first
    // roster row. A budget above 0.99 is refused by the engine.
    if (listed.value.data.len != 0) {
        const model = listed.value.data[0].id;
        try out.print("\nreasoning_effort forms ({s}):\n", .{model});
        try out.writeAll("  budget 0.5: ");
        try ask(&client, out, model, .{ .budget = 0.5 }, null);
        try out.writeAll("  budget 1.0: ");
        try ask(&client, out, model, .{ .budget = 1.0 }, null);
        try out.flush();
    }
}

fn ask(
    client: *lithos.Client,
    out: *Io.Writer,
    model: []const u8,
    effort: chat.ReasoningEffort,
    top_p: ?f64,
) !void {
    const messages = [_]chat.Message{
        .{ .user = .{ .content = chat.text(prompt) } },
    };
    const result = try chat.send(client, &.{
        .model = model,
        .messages = &messages,
        .reasoning_effort = effort,
        .top_p = top_p,
        .max_tokens = 256,
    });
    switch (result) {
        .ok => |parsed| {
            defer parsed.deinit();
            const message = parsed.value.message();
            const reasoning_tokens = if (parsed.value.usage) |usage|
                if (usage.completion_tokens_details) |details| details.reasoning_tokens else null
            else
                null;

            var buffer: [32]u8 = undefined;
            const tokens: []const u8 = if (reasoning_tokens) |count|
                try std.fmt.bufPrint(&buffer, "{d}", .{count})
            else
                "null";
            const reasoned = if (message.reasoning_content) |reasoning| reasoning.len != 0 else false;
            const content_len = if (message.content) |content| content.len else 0;
            const finish: []const u8 = if (parsed.value.choices.len != 0)
                parsed.value.choices[0].finish_reason orelse "?"
            else
                "?";
            try out.print(
                "reasoning_tokens={s} reasoning_content={s} content={d} finish={s}\n",
                .{
                    tokens,
                    if (reasoned) "present" else "empty",
                    content_len,
                    finish,
                },
            );
        },
        .err => |failure| switch (failure) {
            .api => |envelope| {
                var mutable = envelope;
                defer mutable.deinit(client.allocator);
                try out.writeAll("refused: ");
                try mutable.format(out);
                try out.writeByte('\n');
            },
            else => {
                try out.writeAll("refused: ");
                try failure.format(out);
                try out.writeByte('\n');
            },
        },
    }
}