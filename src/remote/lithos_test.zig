//! Tests for the LithosAI client.
//!
//! Two kinds of test, and no socket: the encoding half drives
//! `json_encoder.stringify` over request values and reads the JSON back, and
//! the parsing half feeds canned response bytes to `std.json`. The live
//! behaviour of the API is exercised by `zig build --build-file ./build.research.zig lithos_probe` instead,
//! which needs a key and a network.

const std = @import("std");
const testing = std.testing;

const lithos = @import("lithos.zig");
const chat = lithos.chat;
const models = lithos.models;
const json_encoder = @import("../json_encoder.zig");

fn encoded(value: anytype) ![]u8 {
    return json_encoder.stringify(testing.allocator, value);
}

fn expectJson(value: anytype, expected: []const u8) !void {
    const text = try encoded(value);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

// -- Thinking control -------------------------------------------------------

test "a named reasoning effort encodes as its name" {
    try expectJson(chat.ReasoningEffort{ .named = .high }, "\"high\"");
    try expectJson(chat.ReasoningEffort{ .named = .none }, "\"none\"");
    try expectJson(chat.ReasoningEffort{ .named = .xhigh }, "\"xhigh\"");
}

test "a reasoning budget encodes as a number, not a string" {
    try expectJson(chat.ReasoningEffort{ .budget = 0.5 }, "0.5");
    try expectJson(chat.ReasoningEffort{ .budget = 0 }, "0");
    try expectJson(chat.ReasoningEffort{ .budget = 0.99 }, "0.99");
}

test "a request carries the effort through as the caller wrote it" {
    const messages = [_]chat.Message{
        .{ .user = .{ .content = chat.text("hi") } },
    };
    try expectJson(chat.Request{
        .model = "moonshotai/Kimi-K3",
        .messages = &messages,
        .reasoning_effort = .{ .budget = 0.25 },
    }, "{\"model\":\"moonshotai/Kimi-K3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"reasoning_effort\":0.25}");
}

// -- Request encoding -------------------------------------------------------

test "a request writes fields in the documented order and skips unset ones" {
    const messages = [_]chat.Message{
        .{ .system = .{ .content = chat.text("be brief") } },
        .{ .user = .{ .content = chat.text("hello") } },
    };
    try expectJson(chat.Request{
        .model = "deepseek-ai/DeepSeek-V4.1-Flash",
        .messages = &messages,
        .max_tokens = 64,
        .temperature = 0,
        .stream_options = .{ .include_usage = true },
    }, "{\"model\":\"deepseek-ai/DeepSeek-V4.1-Flash\",\"messages\":[{\"role\":\"system\",\"content\":\"be brief\"},{\"role\":\"user\",\"content\":\"hello\"}],\"max_tokens\":64,\"temperature\":0,\"stream_options\":{\"include_usage\":true}}");
}

test "content is a string for text and an array for parts" {
    try expectJson(chat.text("plain"), "\"plain\"");
    const parts = [_]chat.Part{
        .{ .text = "look:" },
        .{ .image_url = .{ .url = "https://example.test/x.png" } },
    };
    try expectJson(chat.Content{ .parts = &parts }, "[{\"type\":\"text\",\"text\":\"look:\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://example.test/x.png\"}}]");
}

test "a tool choice is a string or a named function object" {
    try expectJson(chat.ToolChoice.auto, "\"auto\"");
    try expectJson(chat.ToolChoice{ .function = "lookup" }, "{\"type\":\"function\",\"function\":{\"name\":\"lookup\"}}");
}

test "stop encodes one sequence as a string and several as an array" {
    try expectJson(chat.Stop{ .sequences = &.{"END"} }, "\"END\"");
    try expectJson(chat.Stop{ .sequences = &.{ "a", "b" } }, "[\"a\",\"b\"]");
}

test "logit_bias encodes as an object keyed by token" {
    try expectJson(chat.LogitBias{ .entries = &.{
        .{ .token = "50256", .bias = -100 },
    } }, "{\"50256\":-100}");
}

test "tools carry a pre-encoded schema verbatim" {
    const tools = [_]chat.Tool{.{
        .function = .{
            .name = "weather",
            .parameters = .{ .text = "{\"type\":\"object\"}" },
        },
    }};
    try expectJson(chat.Request{
        .model = "zai-org/GLM-5.3",
        .messages = &.{.{ .user = .{ .content = chat.text("hi") } }},
        .tools = &tools,
    }, "{\"model\":\"zai-org/GLM-5.3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"weather\",\"parameters\":{\"type\":\"object\"}}}]}");
}

// -- Validation -------------------------------------------------------------

test "validate accepts a well-formed request and names each broken bound" {
    const messages = [_]chat.Message{
        .{ .user = .{ .content = chat.text("hi") } },
    };
    const good = chat.Request{ .model = "zai-org/GLM-5.3", .messages = &messages };
    try testing.expect(good.validate() == .ok);

    const no_model = chat.Request{ .model = "  ", .messages = &messages };
    try testing.expectEqual(chat.Invalid.model_required, no_model.validate().err);

    const no_messages = chat.Request{ .model = "zai-org/GLM-5.3", .messages = &.{} };
    try testing.expectEqual(chat.Invalid.messages_required, no_messages.validate().err);

    const too_hot = chat.Request{ .model = "zai-org/GLM-5.3", .messages = &messages, .temperature = 2.5 };
    try testing.expect(too_hot.validate() == .err);

    const budget = chat.Request{
        .model = "zai-org/GLM-5.3",
        .messages = &messages,
        .reasoning_effort = .{ .budget = 1.0 },
    };
    try testing.expect(budget.validate() == .err);

    const stream_options = chat.Request{
        .model = "zai-org/GLM-5.3",
        .messages = &messages,
        .stream_options = .{},
    };
    try testing.expectEqual(chat.Invalid.stream_options_require_stream, stream_options.validate().err);
}

// -- Error parsing ----------------------------------------------------------

test "the API's own envelope decodes" {
    const body =
        \\{"error":{"message":"n must be 1","type":"invalid_request_error","param":null,"code":"unsupported_n"}}
    ;
    var err = try lithos.parseError(testing.allocator, 400, body);
    defer err.deinit(testing.allocator);
    try testing.expectEqual(lithos.APIError.Form.envelope, err.form);
    try testing.expectEqual(@as(u16, 400), err.status_code);
    try testing.expectEqualStrings("n must be 1", err.message);
    try testing.expectEqualStrings("invalid_request_error", err.type);
    try testing.expectEqualStrings("unsupported_n", err.code);
    try testing.expectEqualStrings("", err.param);
}

test "the engine passthrough decodes, its integer code rendered as text" {
    const body =
        \\{"object":"error","message":"top_p must be between 0.95 and 1.0 for this model; got 0.5","type":"BadRequestError","param":null,"code":400}
    ;
    var err = try lithos.parseError(testing.allocator, 400, body);
    defer err.deinit(testing.allocator);
    try testing.expectEqual(lithos.APIError.Form.engine, err.form);
    try testing.expectEqualStrings("400", err.code);
    try testing.expectEqualStrings("BadRequestError", err.type);
    try testing.expectEqualStrings("top_p must be between 0.95 and 1.0 for this model; got 0.5", err.message);
}

test "a body that is not an envelope is kept whole" {
    const body = "inference error: BadRequest - invalid chat completions request";
    var err = try lithos.parseError(testing.allocator, 400, body);
    defer err.deinit(testing.allocator);
    try testing.expectEqual(lithos.APIError.Form.plain, err.form);
    try testing.expectEqualStrings(body, err.message);
}

test "a 401 envelope without a code decodes" {
    const body =
        \\{"error":{"message":"invalid API key","type":"invalid_request_error"}}
    ;
    var err = try lithos.parseError(testing.allocator, 401, body);
    defer err.deinit(testing.allocator);
    try testing.expectEqualStrings("invalid API key", err.message);
    try testing.expectEqualStrings("", err.code);
}

// -- Response parsing -------------------------------------------------------

test "a completion decodes, reasoning_content and all" {
    const body =
        \\{"id":"chatcmpl-1","object":"chat.completion","created":1791099053,"model":"zai-org/GLM-5.3","choices":[{"index":0,"message":{"role":"assistant","content":null,"reasoning_content":"hmm","tool_calls":null},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":17,"completion_tokens":2,"total_tokens":19,"prompt_tokens_details":null,"completion_tokens_details":{"reasoning_tokens":2}}}
    ;
    const parsed = try std.json.parseFromSlice(chat.Completion, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("chatcmpl-1", parsed.value.id);
    const message = parsed.value.message();
    try testing.expectEqual(@as(?[]const u8, null), message.content);
    try testing.expectEqualStrings("hmm", message.reasoning_content.?);
    try testing.expectEqualStrings("stop", parsed.value.choices[0].finish_reason.?);
    try testing.expectEqual(@as(i64, 2), parsed.value.usage.?.completion_tokens_details.?.reasoning_tokens);
}

test "a chunk with a delta and a null usage decodes" {
    const body =
        \\{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"moonshotai/Kimi-K3","choices":[{"index":0,"delta":{"content":"4"},"finish_reason":null,"logprobs":null}],"usage":null}
    ;
    const parsed = try std.json.parseFromSlice(chat.Chunk, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("4", parsed.value.choices[0].delta.content.?);
    try testing.expectEqual(@as(?lithos.Usage, null), parsed.value.usage);
}

test "a model list decodes" {
    const body =
        \\{"object":"list","data":[{"id":"moonshotai/Kimi-K3","object":"model","created":1785110400,"owned_by":"Moonshot AI"}]}
    ;
    const parsed = try std.json.parseFromSlice(models.List, testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("list", parsed.value.object);
    try testing.expectEqualStrings("moonshotai/Kimi-K3", parsed.value.data[0].id);
    try testing.expectEqualStrings("Moonshot AI", parsed.value.data[0].owned_by);
}
