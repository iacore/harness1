//! Probes whether LithosAI enforces `strict` tool arguments live.
//!
//! A scratch program like `lithos_probe`: it needs a key and a network, so it
//! is neither installed nor built by the default step.
//!
//!   zig build --build-file ./build.research.zig lithos_strict
//!
//! The vendor's OpenAPI reference declares `tools.items` as a bare
//! `type: object`, so it documents no function-object schema and never
//! mentions `strict`. This probe asks the endpoint directly, with four
//! requests that differ only in the schema and the flag:
//!
//!   1. strict, schema that satisfies OpenAI strict rules
//!      (every property required, `additionalProperties: false`) — the
//!      control: a server that enforces strict should still accept it.
//!   2. strict, schema that OpenAI strict rejects (`required` and
//!      `additionalProperties` omitted) — a server that parses strict schemas
//!      answers 400; one that ignores the flag answers 200.
//!   3. strict, schema with `additionalProperties: true` — same discriminator
//!      from the other direction, since OpenAI refuses this too.
//!   4. not strict, the schema of case 2 — the baseline: without the flag the
//!      schema is taken on trust, so this must be 200 whatever the server does
//!      with `strict`.
//!
//! Findings belong in src/remote/lithos_models.md.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const lithos = run1.lithos;
const chat = lithos.chat;
const keys = run1.keys;
const debug = run1.debug;

const model = "deepseek-ai/DeepSeek-V4.1-Flash";
const prompt = "What is the weather in Paris? Call the get_weather tool with the city.";

/// Satisfies OpenAI's strict rules: every property required, nothing else
/// allowed.
const conforming = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"],\"additionalProperties\":false}";

/// OpenAI strict refuses this: no `required`, no `additionalProperties`.
const missing_strict_keys = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}";

/// OpenAI strict refuses this too: `additionalProperties` must be `false`.
const open_object = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"additionalProperties\":true}";

const Case = struct {
    label: []const u8,
    prompt: []const u8 = prompt,
    schema: []const u8,
    strict: ?bool,
};

/// The prompt names Tokyo, the enum allows only Paris. A server that compiles
/// the schema into the decoder cannot emit "Tokyo"; one that ignores `strict`
/// will, because the model has no reason not to.
const enum_schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\",\"enum\":[\"Paris\"]}},\"required\":[\"city\"],\"additionalProperties\":false}";

const cases = [_]Case{
    .{ .label = "strict + conforming schema       ", .schema = conforming, .strict = true },
    .{ .label = "strict + missing strict keys     ", .schema = missing_strict_keys, .strict = true },
    .{ .label = "strict + additionalProperties:true", .schema = open_object, .strict = true },
    .{ .label = "not strict + missing strict keys ", .schema = missing_strict_keys, .strict = false },
    .{
        .label = "strict + enum forbids the city   ",
        .prompt = "What is the weather in Tokyo? Call get_weather with the city Tokyo.",
        .schema = enum_schema,
        .strict = true,
    },
    .{
        .label = "not strict + enum forbids the city",
        .prompt = "What is the weather in Tokyo? Call get_weather with the city Tokyo.",
        .schema = enum_schema,
        .strict = false,
    },
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

    const arena = init.arena.allocator();
    const api_key = try keys.apiKey(arena, io, debug.writer(err_out), init.environ_map, keys.Provider.lithosai) orelse {
        try err_out.writeAll("no LithosAI key: set LITHOSAI_API_KEY, or sign in to the `lithosai` provider of omp\n");
        try err_out.flush();
        return error.ApiKeyRequired;
    };

    var client = try lithos.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    try out.print("model: {s}\n\n", .{model});
    for (cases) |case| try ask(&client, out, case);
    try out.flush();
}

fn ask(client: *lithos.Client, out: *Io.Writer, case: Case) !void {
    const messages = [_]chat.Message{
        .{ .user = .{ .content = chat.text(case.prompt) } },
    };
    const tools = [_]chat.Tool{.{
        .function = .{
            .name = "get_weather",
            .description = "Get the weather for a city.",
            .parameters = .{ .text = case.schema },
            .strict = case.strict,
        },
    }};

    try out.print("{s}: ", .{case.label});
    const result = try chat.send(client, &.{
        .model = model,
        .messages = &messages,
        .tools = &tools,
        .tool_choice = .{ .function = "get_weather" },
        .max_tokens = 128,
    });
    switch (result) {
        .ok => |parsed| {
            defer parsed.deinit();
            const message = parsed.value.message();
            const finish: []const u8 = if (parsed.value.choices.len != 0)
                parsed.value.choices[0].finish_reason orelse "?"
            else
                "?";
            try out.print("200 finish={s}", .{finish});
            if (message.tool_calls) |calls| {
                for (calls) |call| {
                    try out.print(" call={s} args={s}", .{ call.function.name, call.function.arguments });
                }
            } else if (message.content) |content| {
                try out.print(" content={s}", .{content});
            }
            try out.writeByte('\n');
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