//! Tests for the DeepSeek client.
//!
//! FAKE API. Nothing here talks to `api.deepseek.com`. Every test answers
//! through `FakeServer` below: a one-connection-per-reply server we wrote,
//! speaking the API only as we transcribed it from the reference pages. The
//! canned bytes are our reading of those pages, so a field the real API sends
//! that we never wrote into a reply is invisible, and a page we misread passes
//! — client and fixture share the misreading. These tests pin the client to
//! the transcription; they cannot say the transcription is right. Only a run
//! against the live API can, which is `zig build --build-file ./build.research.zig deepseek_playground`.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const deepseek = @import("deepseek.zig");
const Client = deepseek.Client;
const chat = deepseek.chat;
const fim = deepseek.fim;
const json_encoder = @import("../json_encoder.zig");

// Owned by the server's arena.
const Recorded = struct {
    method: []const u8 = "",
    target: []const u8 = "",
    authorization: []const u8 = "",
    content_type: []const u8 = "",
    accept: []const u8 = "",
    body: []const u8 = "",
};

// `parts` is the body, sent as separate flushes when `chunked`, which is what
// a streamed response needs.
const Reply = struct {
    status: u16 = 200,
    content_type: ?[]const u8 = null,
    parts: []const []const u8 = &.{""},
    chunked: bool = false,
};

// The fake API: answers `replies.len` requests, one connection each, with the
// canned `Reply` bytes the test handed it. Not `api.deepseek.com` and never a
// check on it — see the module comment. Connections are closed after every
// reply, so the client cannot reuse one and the accept loop stays in step.
const FakeServer = struct {
    allocator: Allocator,
    io: Io,
    listener: Io.net.Server,
    replies: []const Reply,
    thread: ?std.Thread = null,
    url: []const u8 = "",
    arena: std.heap.ArenaAllocator,
    recorded: std.ArrayListUnmanaged(Recorded) = .empty,
    failures: std.ArrayListUnmanaged([]const u8) = .empty,
    // String parts built for this server, freed on deinit.
    owned_parts: []const []const u8 = &.{},
    stopped: bool = false,

    // `replies` is borrowed and must outlive the server, so pass the address
    // of a caller-local array; a temporary would dangle the moment init
    // returns.
    fn init(allocator: Allocator, io: Io, replies: []const Reply) !FakeServer {
        var address: Io.net.IpAddress = try .parse("127.0.0.1", 0);
        return .{
            .allocator = allocator,
            .io = io,
            .listener = try address.listen(io, .{ .reuse_address = true }),
            .replies = replies,
            .arena = .init(allocator),
        };
    }

    fn start(self: *FakeServer) !void {
        const port = self.listener.socket.address.getPort();
        self.url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}", .{port});
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    // Waits for the server to answer every reply it was given, waking a
    // thread still blocked in accept: a test whose request never arrives must
    // fail on its own error instead of hanging here and hiding it.
    fn finish(self: *FakeServer) void {
        if (self.thread) |thread| {
            // Shutting the listening socket down wakes a blocked accept.
            var listener: Io.net.Stream = .{ .socket = self.listener.socket };
            listener.shutdown(self.io, .both) catch {};
            thread.join();
            self.thread = null;
        }
    }

    fn deinit(self: *FakeServer) void {
        self.finish();
        if (!self.stopped) {
            self.listener.deinit(self.io);
            self.stopped = true;
        }
        if (self.url.len != 0) self.allocator.free(self.url);
        for (self.owned_parts) |part| self.allocator.free(part);
        if (self.owned_parts.len != 0) self.allocator.free(self.owned_parts);
        self.recorded.deinit(self.allocator);
        self.failures.deinit(self.allocator);
        self.arena.deinit();
    }

    // Reports a failure from the server thread, which cannot return an error.
    fn fail(self: *FakeServer, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch return;
        self.failures.append(self.allocator, message) catch {};
    }

    fn expectNoFailures(self: *FakeServer) !void {
        if (self.failures.items.len != 0) {
            std.debug.print("server failures:\n", .{});
            for (self.failures.items) |failure| std.debug.print("  {s}\n", .{failure});
            return error.FakeServerFailed;
        }
    }

    fn run(self: *FakeServer) void {
        const io = self.io;
        for (self.replies) |_| {
            const stream = self.listener.accept(io) catch |err| {
                self.fail("accept: {s}", .{@errorName(err)});
                return;
            };
            defer stream.close(io);
            var read_buffer: [8192]u8 = undefined;
            var write_buffer: [8192]u8 = undefined;
            var body_buffer: [8192]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);
            var server = http.Server.init(&reader.interface, &writer.interface);
            var request = server.receiveHead() catch |err| {
                self.fail("receiveHead: {s}", .{@errorName(err)});
                return;
            };
            self.record(&request) catch |err| {
                self.fail("record: {s}", .{@errorName(err)});
                return;
            };
            self.reply(&request, &body_buffer) catch |err| {
                self.fail("reply: {s}", .{@errorName(err)});
                return;
            };
        }
    }

    fn record(self: *FakeServer, request: *http.Server.Request) !void {
        const arena = self.arena.allocator();
        var recorded: Recorded = .{
            .method = @tagName(request.head.method),
            .target = try arena.dupe(u8, request.head.target),
        };
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            const name = header.name;
            if (std.ascii.eqlIgnoreCase(name, "authorization")) {
                recorded.authorization = try arena.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                recorded.content_type = try arena.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(name, "accept")) {
                recorded.accept = try arena.dupe(u8, header.value);
            }
        }
        if (request.head.content_length) |length| {
            if (length != 0) {
                const body = try arena.alloc(u8, @intCast(length));
                var transfer: [512]u8 = undefined;
                const reader = request.readerExpectNone(&transfer);
                var writer = Io.Writer.fixed(body);
                try reader.streamExact(&writer, body.len);
                recorded.body = body;
            }
        }
        try self.recorded.append(self.allocator, recorded);
    }

    fn reply(self: *FakeServer, request: *http.Server.Request, buffer: []u8) !void {
        const canned = self.replies[self.recorded.items.len - 1];
        var options: http.Server.Request.RespondOptions = .{
            .status = @fromBackingInt(@intCast(canned.status)),
            .keep_alive = false,
        };
        if (canned.content_type) |content_type| {
            options.extra_headers = &.{.{ .name = "content-type", .value = content_type }};
        }
        if (canned.chunked) {
            var body = try request.respondStreaming(buffer, .{ .respond_options = options });
            for (canned.parts) |part| {
                try body.writer.writeAll(part);
                try body.flush();
            }
            try body.end();
        } else {
            var joined: std.ArrayListUnmanaged(u8) = .empty;
            defer joined.deinit(self.allocator);
            for (canned.parts) |part| try joined.appendSlice(self.allocator, part);
            try request.respond(joined.items, options);
        }
    }
};

// The server must outlive the returned client.
fn testClient(allocator: Allocator, server: *const FakeServer, beta: bool) !Client {
    return Client.init(allocator, testing.io, "test-key", .{
        .base_url = server.url,
        .beta = beta,
    });
}

fn expectRequest(recorded: Recorded, target: []const u8) !void {
    try testing.expectEqualStrings("POST", recorded.method);
    try testing.expectEqualStrings(target, recorded.target);
    try testing.expectEqualStrings("Bearer test-key", recorded.authorization);
    try testing.expectEqualStrings("application/json", recorded.content_type);
}

// The payload of a `Result`, by variant name.
fn Payload(comptime R: type, comptime which: []const u8) type {
    const info = @typeInfo(R).@"union";
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (std.mem.eql(u8, name, which)) return field_type;
    }
    @compileError(@typeName(R) ++ " is not a Result");
}

fn unwrap(result: anytype) !Payload(@TypeOf(result), "ok") {
    return switch (result) {
        .ok => |value| value,
        .err => |failure| {
            std.debug.print("call failed: {f}\n", .{failure});
            return error.UnexpectedFailure;
        },
    };
}

fn expectFailure(result: anytype, comptime tag: std.meta.Tag(Payload(@TypeOf(result), "err"))) !Payload(@TypeOf(result), "err") {
    switch (result) {
        .ok => {
            std.debug.print("expected a failure, got a value\n", .{});
            return error.ExpectedFailure;
        },
        .err => |failure| {
            if (std.meta.activeTag(failure) != tag) {
                std.debug.print("expected .{s}, got {f}\n", .{ @tagName(tag), failure });
                return error.UnexpectedFailureTag;
            }
            return failure;
        },
    }
}

fn sendChat(client: *Client, request: *const chat.Request) !json.Parsed(chat.Completion) {
    return unwrap(try chat.send(client, request));
}

fn streamChat(client: *Client, request: *const chat.Request) !chat.Stream {
    return unwrap(try chat.sendStream(client, request));
}

fn sendFim(client: *Client, request: *const fim.Request) !json.Parsed(fim.Completion) {
    return unwrap(try fim.send(client, request));
}

fn streamFim(client: *Client, request: *const fim.Request) !fim.Stream {
    return unwrap(try fim.sendStream(client, request));
}

// ------------------------------------------------------------------ chat ---
//
// Contract tests for POST /chat/completions. Every expectation below comes
// from the endpoint's reference page, https://api-docs.deepseek.com/api/create-chat-completion,
// and the guides it links: https://api-docs.deepseek.com/guides/chat_prefix_completion
// for prefix completion, https://api-docs.deepseek.com/guides/tool_calls for
// the tool and strict-mode shapes.

// The request body the reference page documents, field for field, with the
// Beta-only features (strict tool, which the page points at for the Beta
// root) enabled.
test "the documented chat request body" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{
        .content_type = "application/json",
        .parts = &.{
            \\{"id":"x","object":"chat.completion","choices":[]}
        },
    }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, true);
    defer client.deinit();

    // The schema the reference page writes as JSON, as Zig values. `required`
    // and `additionalProperties` are not fields of `StrictSchema`: strict mode
    // reads both off the property names and off the mode, so the encoder
    // writes them, and `parameters` below is what they come to.
    const schema: chat.StrictSchema = .{
        .type = .object,
        .properties = &.{.{ .name = "city", .schema = .{ .type = .string } }},
    };
    const parameters =
        \\{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}
    ;
    const messages = [_]chat.Message{
        .{ .system = .{ .content = "be brief" } },
        .{ .user = .{ .content = chat.text("hi") } },
    };
    const tools = [_]chat.Tool{.{
        .function = .{
            .name = "get_weather",
            .description = "Get the weather.",
            .parameters = .{ .strict = schema },
        },
    }};
    const completion = try sendChat(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
        .thinking = .enabled,
        .reasoning_effort = .max,
        .max_tokens = 512,
        .response_format = .json_object,
        .stop = .{ .sequences = &.{"END"} },
        .temperature = 0.2,
        .top_p = 0.99,
        .tools = &tools,
        .tool_choice = .{ .mode = .auto },
        .logprobs = true,
        .top_logprobs = 3,
        .user_id = "user-1",
    });
    defer completion.deinit();
    server.finish();
    try server.expectNoFailures();

    const recorded = server.recorded.items[0];
    try expectRequest(recorded, "/beta/chat/completions");
    const want = try std.mem.concat(gpa, u8, &.{
        \\{"model":"deepseek-flash","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hi"}],"thinking":{"type":"enabled"},"reasoning_effort":"max","max_tokens":512,"response_format":{"type":"json_object"},"stop":"END","temperature":0.2,"top_p":0.99,"tools":[{"type":"function","function":{"name":"get_weather","description":"Get the weather.","parameters":
        ,
        parameters,
        \\,"strict":true}}],"tool_choice":"auto","logprobs":true,"top_logprobs":3,"user_id":"user-1"}
    });
    defer gpa.free(want);
    try testing.expectEqualStrings(want, recorded.body);
}

// Strict and not-strict are two modes over a schema, so each has its own
// shape on the wire: `strict` rides beside the schema in the mode that asks
// for checking, and a schema alone is what the server takes on trust. The
// same object written in both modes differs by exactly those two keywords,
// which `StrictSchema` writes from the property names and `Schema` takes from
// the caller. A function that takes nothing sends neither.
test "a tool's parameters carry their mode" {
    const gpa = testing.allocator;
    const schema_json =
        \\{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}
    ;

    const strict = try json_encoder.stringify(gpa, chat.Tool{
        .function = .{
            .name = "get_weather",
            .parameters = .{ .strict = .{
                .type = .object,
                .properties = &.{.{ .name = "city", .schema = .{ .type = .string } }},
            } },
        },
    });
    defer gpa.free(strict);

    const trusting = try json_encoder.stringify(gpa, chat.Tool{
        .function = .{
            .name = "get_weather",
            .parameters = .{ .not_strict = .{
                .type = .object,
                .properties = &.{.{ .name = "city", .schema = .{ .type = .string } }},
                .required = &.{"city"},
                .additional_properties = false,
            } },
        },
    });
    defer gpa.free(trusting);

    const bare = try json_encoder.stringify(gpa, chat.Tool{
        .function = .{ .name = "get_weather" },
    });
    defer gpa.free(bare);

    const want_strict = try std.mem.concat(gpa, u8, &.{
        \\{"type":"function","function":{"name":"get_weather","parameters":
        ,
        schema_json,
        \\,"strict":true}}
    });
    defer gpa.free(want_strict);
    try testing.expectEqualStrings(want_strict, strict);

    const want_trusting = try std.mem.concat(gpa, u8, &.{
        \\{"type":"function","function":{"name":"get_weather","parameters":
        ,
        schema_json,
        \\}}
    });
    defer gpa.free(want_trusting);
    try testing.expectEqualStrings(want_trusting, trusting);

    try testing.expectEqualStrings(
        \\{"type":"function","function":{"name":"get_weather"}}
    , bare);
}

// Every keyword of the documented subset, written as Zig values: the shapes
// under one object, an array with its items, an enum beside a type, an anyOf
// instead of one, a `$ref` into `$def`, and the string and number keywords.
test "a schema writes the keywords the API documents" {
    const gpa = testing.allocator;
    const schema: chat.Schema = .{
        .description = "A report.",
        .type = .object,
        .properties = &.{
            .{ .name = "count", .schema = .{
                .type = .integer,
                .const_value = .{ .integer = 3 },
                .default = .{ .integer = 3 },
                .minimum = 1,
                .maximum = 10,
                .exclusive_minimum = 0,
                .exclusive_maximum = 11,
                .multiple_of = 2,
            } },
            .{ .name = "status", .schema = .{
                .type = .string,
                .enumeration = &.{ .{ .string = "pending" }, .{ .string = "shipped" } },
            } },
            .{ .name = "email", .schema = .{
                .type = .string,
                .pattern = "^[0-9]{11}$",
                .format = .email,
            } },
            .{ .name = "author", .schema = .{ .ref = "#/$def/author" } },
            .{ .name = "account", .schema = .{ .any_of = &.{
                .{ .type = .string, .format = .email },
                .{ .type = .string, .pattern = "^[0-9]{11}$" },
            } } },
            .{ .name = "tags", .schema = .{ .type = .array, .items = &.{ .type = .string } } },
            .{ .name = "flag", .schema = .{ .type = .boolean } },
        },
        .required = &.{"count"},
        .additional_properties = false,
        .defs = &.{.{ .name = "author", .schema = .{
            .type = .object,
            .properties = &.{.{ .name = "name", .schema = .{ .type = .string } }},
        } }},
    };
    const body = try json_encoder.stringify(gpa, schema);
    defer gpa.free(body);
    try testing.expectEqualStrings(
        \\{"$def":{"author":{"type":"object","properties":{"name":{"type":"string"}}}},"description":"A report.","type":"object","properties":{"count":{"type":"integer","const":3,"default":3,"minimum":1,"maximum":10,"exclusiveMinimum":0,"exclusiveMaximum":11,"multipleOf":2},"status":{"type":"string","enum":["pending","shipped"]},"email":{"type":"string","pattern":"^[0-9]{11}$","format":"email"},"author":{"$ref":"#/$def/author"},"account":{"anyOf":[{"type":"string","format":"email"},{"type":"string","pattern":"^[0-9]{11}$"}]},"tags":{"type":"array","items":{"type":"string"}},"flag":{"type":"boolean"}},"required":["count"],"additionalProperties":false}
    , body);
}

// Strict mode is one of the two features the plain root refuses. The refusal
// is about the mode, and it happens before a request is built, so nothing
// reaches the wire.
test "a strict tool needs the Beta root" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{ .parts = &.{
        \\{"id":"x","choices":[]}
    } }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, false);
    defer client.deinit();

    const messages = [_]chat.Message{.{ .user = .{ .content = chat.text("hi") } }};
    const strict = [_]chat.Tool{.{
        .function = .{ .name = "f", .parameters = .{ .strict = .{ .type = .object } } },
    }};
    const trusting = [_]chat.Tool{.{
        .function = .{ .name = "f", .parameters = .{ .not_strict = .{ .type = .object } } },
    }};

    const refused = try chat.send(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
        .tools = &strict,
    });
    _ = try expectFailure(refused, .strict_tools_require_beta);

    // The same schema in the other mode asks for no checking, so it goes out.
    const completion = try sendChat(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
        .tools = &trusting,
    });
    defer completion.deinit();
    server.finish();
    try server.expectNoFailures();
    try testing.expectEqual(1, server.recorded.items.len);
}

// The reference page documents every parameter but `model` and `messages` as
// optional. Nothing unset may appear in the body.
test "unset chat parameters are absent from the body" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{ .parts = &.{
        \\{"id":"x","object":"chat.completion","choices":[]}
    } }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, false);
    defer client.deinit();

    const messages = [_]chat.Message{.{ .user = .{ .content = chat.text("hi") } }};
    const completion = try sendChat(&client, &.{
        .model = deepseek.Model.v4_pro,
        .messages = &messages,
    });
    defer completion.deinit();
    server.finish();
    try server.expectNoFailures();

    try testing.expectEqualStrings(
        \\{"model":"deepseek-v4-pro","messages":[{"role":"user","content":"hi"}]}
    , server.recorded.items[0].body);
}

// The four message roles the reference page lists — system, user, assistant
// and tool — each with their own fields: text, image_url and file content
// parts, tool calls with their results, and the prefix that
// https://api-docs.deepseek.com/guides/chat_prefix_completion requires on the
// last message.
test "the documented message shapes" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{ .parts = &.{
        \\{"id":"x","choices":[]}
    } }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, true);
    defer client.deinit();

    const messages = [_]chat.Message{
        .{ .user = .{ .content = .{ .parts = &.{
            chat.textPart("what is this?"),
            chat.imageUrlPart("https://example.com/a.png", .low),
        } } } },
        .{ .assistant = .{ .content = .{ .text = "" }, .tool_calls = &.{.{
            .id = "call_1",
            .type = chat.ToolType.function,
            .function = .{ .name = "get_weather", .arguments = "{\"city\":\"Hangzhou\"}" },
            .index = 0,
        }} } },
        .{ .tool = chat.toolResult("call_1", "24C") },
        .{ .assistant = .{
            .content = chat.text("It is "),
            .reasoning_content = "thinking",
            .prefix = true,
        } },
    };
    const completion = try sendChat(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
        .tool_choice = .{ .mode = .none },
    });
    defer completion.deinit();
    server.finish();
    try server.expectNoFailures();

    // An assistant turn that only calls a tool sends content as an empty
    // string, and a streamed chunk's index never leaks into a request.
    const want = try std.mem.concat(gpa, u8, &.{
        \\{"model":"deepseek-flash","messages":[{"role":"user","content":[{"type":"text","text":"what is this?"},{"type":"image_url","image_url":{"url":"https://example.com/a.png","detail":"low"}}]},{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":
        ,
        \\"{\"city\":\"Hangzhou\"}"
        ,
        \\}}]},{"role":"tool","content":"24C","tool_call_id":"call_1"},{"role":"assistant","content":"It is ","reasoning_content":"thinking","prefix":true}],"tool_choice":"none"}
    });
    defer gpa.free(want);
    try testing.expectEqualStrings(want, server.recorded.items[0].body);
}

// The reference page's curl example sends `Authorization: Bearer`, and asks
// for `Accept: text/event-stream` when `stream` is set.
test "the documented request headers" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{
        .content_type = "text/event-stream",
        .chunked = true,
        .parts = &.{
            \\data: [DONE]
            \\
            \\
        },
    }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, false);
    defer client.deinit();

    const messages = [_]chat.Message{.{ .user = .{ .content = chat.text("hi") } }};
    var stream = try streamChat(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
    });
    defer stream.deinit();
    server.finish();
    try server.expectNoFailures();

    const recorded = server.recorded.items[0];
    try expectRequest(recorded, "/chat/completions");
    try testing.expectEqualStrings("text/event-stream", recorded.accept);
}

// The reference page gives one API root; https://api-docs.deepseek.com/guides/fim_completion
// and the prefix-completion guide put the Beta endpoints under `/beta`.
test "the documented API roots" {
    const gpa = testing.allocator;
    const cases = [_]struct {
        beta: bool,
        trailing_slash: bool,
        want: []const u8,
    }{
        .{ .beta = false, .trailing_slash = false, .want = "/chat/completions" },
        .{ .beta = false, .trailing_slash = true, .want = "/chat/completions" },
        .{ .beta = true, .trailing_slash = false, .want = "/beta/chat/completions" },
        .{ .beta = true, .trailing_slash = true, .want = "/beta/chat/completions" },
    };
    for (cases) |case| {
        const replies = [_]Reply{.{ .parts = &.{
            \\{"id":"x","choices":[]}
        } }};
        var server = try FakeServer.init(gpa, testing.io, &replies);
        defer server.deinit();
        try server.start();

        const base = if (case.trailing_slash)
            try std.fmt.allocPrint(gpa, "{s}/", .{server.url})
        else
            try gpa.dupe(u8, server.url);
        defer gpa.free(base);

        var client = try Client.init(gpa, testing.io, "test-key", .{
            .base_url = base,
            .beta = case.beta,
        });
        defer client.deinit();

        const messages = [_]chat.Message{.{ .user = .{ .content = chat.text("hi") } }};
        const completion = try sendChat(&client, &.{
            .model = deepseek.Model.flash,
            .messages = &messages,
        });
        defer completion.deinit();
        server.finish();
        try server.expectNoFailures();
        try testing.expectEqualStrings(case.want, server.recorded.items[0].target);
    }
}

// A failed request answers with the error envelope the reference page
// documents, whose `code` the API sends as a string or as a number.
test "the documented error envelope" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{
        .status = 429,
        .content_type = "application/json",
        .parts = &.{
            \\{"error":{"message":"Rate limit reached","type":"rate_limit_error","param":null,"code":429001}}
        },
    }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, false);
    defer client.deinit();

    const messages = [_]chat.Message{.{ .user = .{ .content = chat.text("hi") } }};
    const result = try chat.send(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
    });
    var envelope = (try expectFailure(result, .api)).api;
    defer envelope.deinit(gpa);
    server.finish();
    try server.expectNoFailures();

    try testing.expectEqual(429, envelope.status_code);
    try testing.expectEqualStrings("rate_limit_error", envelope.type);
    try testing.expectEqualStrings("429001", envelope.code);
    try testing.expectEqualStrings("Rate limit reached", envelope.message);
}

// The completion fields the reference page's response example carries.
test "the documented chat completion response" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{
        .content_type = "application/json",
        .parts = &.{
            \\{
            \\  "id": "930c60df",
            \\  "object": "chat.completion",
            \\  "created": 1705651092,
            \\  "model": "deepseek-flash",
            \\  "system_fingerprint": "fp_7a09fdf9c2",
            \\  "choices": [{
            \\    "index": 0,
            \\    "finish_reason": "tool_calls",
            \\    "message": {
            \\      "role": "assistant",
            \\      "content": "",
            \\      "reasoning_content": "I should check the weather.",
            \\      "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"Hangzhou\"}"}}]
            \\    },
            \\    "logprobs": {"content": [{"token": "The", "logprob": -0.1, "bytes": [84], "top_logprobs": [{"token": "The", "logprob": -0.1, "bytes": [84]}]}]}
            \\  }],
            \\  "usage": {
            \\    "completion_tokens": 43,
            \\    "prompt_tokens": 17,
            \\    "total_tokens": 60,
            \\    "prompt_cache_hit_tokens": 1,
            \\    "prompt_cache_miss_tokens": 16,
            \\    "prompt_tokens_details": {"cached_tokens": 1},
            \\    "completion_tokens_details": {"reasoning_tokens": 30}
            \\  }
            \\}
        },
    }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, false);
    defer client.deinit();

    const messages = [_]chat.Message{.{ .user = .{ .content = chat.text("weather?") } }};
    const parsed = try sendChat(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
    });
    defer parsed.deinit();
    const completion = parsed.value;
    server.finish();
    try server.expectNoFailures();

    try testing.expectEqualStrings("930c60df", completion.id);
    try testing.expectEqualStrings("chat.completion", completion.object);
    try testing.expectEqual(1705651092, completion.created);
    try testing.expectEqualStrings("fp_7a09fdf9c2", completion.system_fingerprint);
    try testing.expectEqualStrings(chat.FinishReason.tool_calls, completion.choices[0].finish_reason.?);
    try testing.expectEqualStrings("I should check the weather.", completion.choices[0].message.reasoning_content.?);
    try testing.expectEqualStrings("{\"city\":\"Hangzhou\"}", completion.choices[0].message.tool_calls[0].function.arguments);
    try testing.expectEqual(84, completion.choices[0].logprobs.?.content[0].bytes.?[0]);
    try testing.expectEqual(-0.1, completion.choices[0].logprobs.?.content[0].logprob);

    const usage = completion.usage.?;
    try testing.expectEqual(43, usage.completion_tokens);
    try testing.expectEqual(17, usage.prompt_tokens);
    try testing.expectEqual(60, usage.total_tokens);
    try testing.expectEqual(1, usage.prompt_cache_hit_tokens);
    try testing.expectEqual(16, usage.prompt_cache_miss_tokens);
    try testing.expectEqual(1, usage.prompt_tokens_details.?.cached_tokens);
    try testing.expectEqual(30, usage.completion_tokens_details.?.reasoning_tokens);

    // The reply replays as an assistant turn, which tool calling needs: the
    // tool calls, and the chain of thought the API requires alongside them.
    const replay = completion.message().toAssistant();
    try testing.expectEqualStrings("I should check the weather.", replay.reasoning_content.?);
    try testing.expectEqual(0, replay.content.text.len);
    try testing.expectEqualStrings("call_1", replay.tool_calls.?[0].id.?);
}

// The streaming section of the reference page: chunks of `chat.completion.chunk`
// carrying `choices[].delta`, the tokens billed on the last one, and the
// `data: [DONE]` sentinel that ends the stream. Collected, they must add up to
// the same completion a non-streaming call returns.
test "the documented chat stream" {
    const gpa = testing.allocator;
    const events = [_][]const u8{
        \\{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","system_fingerprint":"fp_a49","choices":[{"index":0,"delta":{"role":"assistant","content":null,"reasoning_content":null},"finish_reason":null,"logprobs":null}]}
        ,
        \\{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":"The answer is ","reasoning_content":"2+2"},"finish_reason":null}]}
        ,
        \\{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"ci"}}]},"finish_reason":null}]}
        ,
        \\{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":null,"type":"function","function":{"name":null,"arguments":"ty\":\"Hangzhou\"}"}}]},"finish_reason":null}]}
        ,
        \\{"id":"1f63","object":"chat.completion.chunk","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"delta":{"content":""},"finish_reason":"tool_calls","logprobs":{"content":[{"token":"4","logprob":-0.5,"bytes":[52],"top_logprobs":null}]}}],"usage":{"completion_tokens":9,"prompt_tokens":17,"total_tokens":26,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":17}}
        ,
    };
    var replies: [2]Reply = undefined;
    var server = try startStreamServer(gpa, &events, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, true);
    defer client.deinit();

    const messages = [_]chat.Message{.{ .user = .{ .content = chat.text("weather and date?") } }};
    const request: chat.Request = .{ .model = deepseek.Model.flash, .messages = &messages };
    var stream = try streamChat(&client, &request);
    defer stream.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const first = (try stream.recv(a)).?;
    try testing.expectEqualStrings(chat.Object.completion_chunk, first.object);
    try testing.expectEqualStrings(chat.Role.assistant, first.choices[0].delta.role.?);
    // Text the API has none of arrives as null, on both texts at once: the
    // chunk that opens a thinking-mode answer carries nothing but the role.
    try testing.expectEqual(null, first.choices[0].delta.content);
    try testing.expectEqual(null, first.choices[0].delta.reasoning_content);

    const second = (try stream.recv(a)).?;
    try testing.expectEqualStrings("The answer is ", second.choices[0].delta.content.?);
    try testing.expectEqualStrings("2+2", second.choices[0].delta.reasoning_content.?);

    // A tool call arrives in fragments, the first carrying its id and name. A
    // later fragment repeats neither: the endpoint sends JSON null for both,
    // and what it does not send must not be read as an empty name.
    const third = (try stream.recv(a)).?;
    try testing.expectEqual(0, third.choices[0].delta.tool_calls.?[0].index.?);
    try testing.expectEqualStrings("call_1", third.choices[0].delta.tool_calls.?[0].id.?);
    try testing.expectEqualStrings("get_weather", third.choices[0].delta.tool_calls.?[0].function.name.?);
    try testing.expectEqualStrings("{\"ci", third.choices[0].delta.tool_calls.?[0].function.arguments.?);

    const fourth = (try stream.recv(a)).?;
    try testing.expectEqual(null, fourth.choices[0].delta.tool_calls.?[0].id);
    try testing.expectEqual(null, fourth.choices[0].delta.tool_calls.?[0].function.name);
    try testing.expectEqualStrings("ty\":\"Hangzhou\"}", fourth.choices[0].delta.tool_calls.?[0].function.arguments.?);

    const last = (try stream.recv(a)).?;
    try testing.expectEqualStrings(chat.FinishReason.tool_calls, last.choices[0].finish_reason.?);
    try testing.expectEqual(26, last.usage.?.total_tokens);
    try testing.expectEqual(17, stream.usage().?.prompt_cache_miss_tokens);
    try testing.expect(try stream.recv(a) == null);

    // The deltas add up to the completion a non-streaming call returns, whose
    // fragments the accumulator has to join.
    var second_stream = try streamChat(&client, &request);
    defer second_stream.deinit();
    var collected = try second_stream.collect(gpa);
    defer collected.deinit();
    try testing.expectEqualStrings(chat.Object.completion, collected.value.object);
    try testing.expectEqualStrings("The answer is ", collected.value.choices[0].message.content.?);
    try testing.expectEqualStrings("2+2", collected.value.choices[0].message.reasoning_content.?);
    try testing.expectEqualStrings(
        "{\"city\":\"Hangzhou\"}",
        collected.value.choices[0].message.tool_calls[0].function.arguments,
    );
    // The name came on the first fragment and is not overwritten by the
    // fragment that repeats it as null.
    try testing.expectEqualStrings("get_weather", collected.value.choices[0].message.tool_calls[0].function.name);
    try testing.expectEqual(17, collected.value.usage.?.prompt_tokens);
    // The request goes out with `stream` set whatever the request said — it
    // was left null here — which is what makes this endpoint answer with
    // events.
    try testing.expectEqualStrings(
        \\{"model":"deepseek-flash","messages":[{"role":"user","content":"weather and date?"}],"stream":true}
    , server.recorded.items[0].body);
    server.finish();
    try server.expectNoFailures();
}

// The API's two texts are documented nullable, and it uses the null: in
// thinking mode — the default — the chain of thought arrives with
// `content: null` and the answer proper with `reasoning_content: null`. A
// field that is not optional does not decode a `null` at all, default or no
// default, so the whole chunk it is in fails rather than reading as empty.
test "text the API sent as null decodes as nothing" {
    const message = try std.json.parseFromSliceLeaky(chat.GeneratedMessage, testing.allocator,
        \\{"role":"assistant","content":null,"reasoning_content":null}
    , .{});
    try testing.expectEqual(null, message.content);
    try testing.expectEqual(null, message.reasoning_content);

    const delta = try std.json.parseFromSliceLeaky(chat.Delta, testing.allocator,
        \\{"content":null,"reasoning_content":"thinking"}
    , .{});
    try testing.expectEqual(null, delta.content);
    try testing.expectEqualStrings("thinking", delta.reasoning_content.?);
}

// What the API requires back on a tool-calling turn is the chain of thought
// field, present, and not a value in it: the model calls a tool without
// thinking often enough that it answers with an empty one, and the API takes
// `""` where it refuses the field's absence. So an empty one is written and an
// absent one is left out — a client that dropped empty strings could not send
// such a turn back at all, and one that wrote nulls would put a chain of
// thought on every turn that never had one.
test "an empty chain of thought is replayed and an absent one is left out" {
    const gpa = testing.allocator;
    const calls = [_]chat.ToolCall{.{
        .id = "c1",
        .type = chat.ToolType.function,
        .function = .{ .name = "f", .arguments = "{}" },
    }};

    const thoughtless = [_]chat.Message{
        .{ .user = .{ .content = chat.text("weather?") } },
        .{ .assistant = .{ .tool_calls = &calls, .reasoning_content = "" } },
        .{ .tool = chat.toolResult("c1", "ok") },
    };
    const replayed: chat.Request = .{ .model = deepseek.Model.flash, .messages = &thoughtless };
    try testing.expectEqual(null, replayed.validate().failure());

    const body = try json_encoder.stringify(gpa, replayed);
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"\"") != null);

    const never = [_]chat.Message{
        .{ .user = .{ .content = chat.text("hi") } },
        .{ .assistant = .{ .content = chat.text("hello") } },
    };
    const plain: chat.Request = .{ .model = deepseek.Model.flash, .messages = &never };
    const plain_body = try json_encoder.stringify(gpa, plain);
    defer gpa.free(plain_body);
    try testing.expect(std.mem.indexOf(u8, plain_body, "reasoning_content") == null);
}

// Every limit the reference page states for a chat parameter.
test "the documented chat parameter limits" {
    const gpa = testing.allocator;
    const user = chat.Message{ .user = .{ .content = chat.text("hi") } };
    const assistant = chat.Message{ .assistant = .{ .content = chat.text("hello") } };
    const call = chat.ToolCall{
        .id = "c1",
        .type = chat.ToolType.function,
        .function = .{ .name = "f", .arguments = "{}" },
    };
    const tools = [_]chat.Tool{.{ .function = .{ .name = "f" } }};
    const calls = [_]chat.ToolCall{call};
    const duplicate_calls = [_]chat.ToolCall{ call, call };
    const long_url = try gpa.alloc(u8, chat.max_image_url_len + 1);
    defer gpa.free(long_url);
    @memset(long_url, 'a');
    const too_many_stops = try gpa.alloc([]const u8, chat.max_stop_sequences + 1);
    defer gpa.free(too_many_stops);
    @memset(too_many_stops, "stop");
    const stops_at_limit = try gpa.alloc([]const u8, chat.max_stop_sequences);
    defer gpa.free(stops_at_limit);
    @memset(stops_at_limit, "stop");

    const one_message = [_]chat.Message{user};
    const call_turn = [_]chat.Message{ user, .{ .assistant = .{ .tool_calls = &calls } }, .{ .tool = chat.toolResult("c1", "ok") } };
    const replayed = [_]chat.Message{ user, .{ .assistant = .{ .tool_calls = &calls, .reasoning_content = "why" } }, .{ .tool = chat.toolResult("c1", "ok") } };
    const replayed_empty = [_]chat.Message{ user, .{ .assistant = .{ .tool_calls = &calls, .reasoning_content = "" } }, .{ .tool = chat.toolResult("c1", "ok") } };
    const unreasoned = [_]chat.Message{ user, .{ .assistant = .{ .tool_calls = &calls } }, .{ .tool = chat.toolResult("c1", "ok") } };
    const prefix = [_]chat.Message{ user, .{ .assistant = .{ .content = chat.text("```python\n"), .prefix = true } } };
    const prefix_not_last = [_]chat.Message{ .{ .assistant = .{ .content = chat.text("Once"), .prefix = true } }, user };
    const prefix_without_content = [_]chat.Message{ user, .{ .assistant = .{ .content = chat.text(""), .prefix = true } } };
    const unknown_call = [_]chat.Message{ user, .{ .assistant = .{ .tool_calls = &calls } }, .{ .tool = chat.toolResult("other", "ok") } };
    const duplicate = [_]chat.Message{ user, .{ .assistant = .{ .tool_calls = &duplicate_calls } } };
    const image_in_assistant = [_]chat.Message{.{ .assistant = .{ .content = .{ .parts = &.{chat.imageUrlPart("https://e.com/a.png", null)} } } }};
    const image_without_url = [_]chat.Message{.{ .user = .{ .content = .{ .parts = &.{chat.imageUrlPart("", null)} } } }};
    const long_image_url = [_]chat.Message{.{ .user = .{ .content = .{ .parts = &.{chat.imageUrlPart(long_url, null)} } } }};
    const empty_text = [_]chat.Message{.{ .user = .{ .content = .{ .parts = &.{chat.textPart("")} } } }};
    const empty_user = [_]chat.Message{.{ .user = .{ .content = chat.text("") } }};
    const empty_system = [_]chat.Message{.{ .system = .{ .content = "" } }};
    const tool_without_id = [_]chat.Message{ user, .{ .tool = .{ .tool_call_id = "", .content = "ok" } } };
    const empty_tool_result = [_]chat.Message{ user, .{ .assistant = .{ .tool_calls = &calls } }, .{ .tool = chat.toolResult("c1", "") } };
    const assistant_without_content = [_]chat.Message{ assistant, .{ .assistant = .{ .content = chat.text("") } } };
    const unnamed_tools = [_]chat.Tool{.{}};
    const bad_name_tools = [_]chat.Tool{.{ .function = .{ .name = "get weather" } }};
    const duplicate_tools = [_]chat.Tool{ .{ .function = .{ .name = "f" } }, .{ .function = .{ .name = "f" } } };

    const Case = struct {
        name: []const u8,
        request: chat.Request,
        want: ?chat.Invalid = null,
    };
    const cases = [_]Case{
        .{ .name = "minimal", .request = .{ .model = deepseek.Model.flash, .messages = &one_message } },
        .{ .name = "tool call turn", .request = .{ .model = deepseek.Model.flash, .messages = &call_turn } },
        .{ .name = "prefix on the last assistant message", .request = .{ .model = deepseek.Model.flash, .messages = &prefix } },
        .{ .name = "thinking disabled allows required tool choice", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .thinking = .disabled, .tools = &tools, .tool_choice = .{ .mode = .required } } },
        .{ .name = "assistant tool call replayed with reasoning is allowed", .request = .{ .model = deepseek.Model.flash, .messages = &replayed, .tools = &tools } },
        .{ .name = "assistant tool call replayed with an empty chain of thought is allowed", .request = .{ .model = deepseek.Model.flash, .messages = &replayed_empty, .tools = &tools } },
        .{ .name = "non-thinking requests need no reasoning", .request = .{ .model = deepseek.Model.flash, .messages = &unreasoned, .thinking = .disabled, .tools = &tools } },
        // The accepting side of each limit the rows below reject. Without
        // these, a comparison off by one at the boundary passes on the
        // strength of the rejection alone.
        .{ .name = "max_tokens at its floor", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .max_tokens = 1 } },
        .{ .name = "max_tokens at its ceiling", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .max_tokens = chat.max_output_tokens } },
        .{ .name = "temperature at its floor", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .temperature = 0.0 } },
        .{ .name = "temperature at its ceiling", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .temperature = 2.0 } },
        .{ .name = "top_p at its ceiling", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .top_p = 1.0 } },
        .{ .name = "top_logprobs at its floor", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .logprobs = true, .top_logprobs = 0 } },
        .{ .name = "top_logprobs at its ceiling", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .logprobs = true, .top_logprobs = chat.max_top_logprobs } },
        .{ .name = "stop sequences at the limit", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .stop = .{ .sequences = stops_at_limit } } },
        .{ .name = "missing model", .request = .{ .model = "", .messages = &one_message }, .want = .model_required },
        .{ .name = "no messages", .request = .{ .model = deepseek.Model.flash, .messages = &.{} }, .want = .messages_required },
        .{ .name = "user message without content", .request = .{ .model = deepseek.Model.flash, .messages = &empty_user }, .want = .{ .message_content_required = 0 } },
        .{ .name = "system message without content", .request = .{ .model = deepseek.Model.flash, .messages = &empty_system }, .want = .{ .message_content_required = 0 } },
        .{ .name = "tool message without tool_call_id", .request = .{ .model = deepseek.Model.flash, .messages = &tool_without_id }, .want = .{ .tool_call_id_required = 1 } },
        .{ .name = "tool message with an unknown tool_call_id", .request = .{ .model = deepseek.Model.flash, .messages = &unknown_call }, .want = .{ .tool_call_id_unknown = "other" } },
        .{ .name = "duplicate tool call ids", .request = .{ .model = deepseek.Model.flash, .messages = &duplicate }, .want = .{ .tool_call_id_reused = "c1" } },
        .{ .name = "image in an assistant message", .request = .{ .model = deepseek.Model.flash, .messages = &image_in_assistant }, .want = .{ .part_not_allowed_for_role = 0 } },
        .{ .name = "image without a url", .request = .{ .model = deepseek.Model.flash, .messages = &image_without_url }, .want = .{ .image_url_required = 0 } },
        .{ .name = "over-long image url", .request = .{ .model = deepseek.Model.flash, .messages = &long_image_url }, .want = .{ .image_url_too_long = chat.max_image_url_len + 1 } },
        .{ .name = "missing text of a text part", .request = .{ .model = deepseek.Model.flash, .messages = &empty_text }, .want = .{ .text_part_required = 0 } },
        .{ .name = "max_tokens above the ceiling", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .max_tokens = chat.max_output_tokens + 1 }, .want = .{ .max_tokens_out_of_range = chat.max_output_tokens + 1 } },
        .{ .name = "max_tokens zero", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .max_tokens = 0 }, .want = .{ .max_tokens_out_of_range = 0 } },
        .{ .name = "temperature out of range", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .temperature = 2.5 }, .want = .{ .temperature_out_of_range = 2.5 } },
        .{ .name = "top_p out of range", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .top_p = 0.0 }, .want = .{ .top_p_out_of_range = 0 } },
        .{ .name = "top_logprobs above the ceiling", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .logprobs = true, .top_logprobs = chat.max_top_logprobs + 1 }, .want = .{ .top_logprobs_out_of_range = chat.max_top_logprobs + 1 } },
        .{ .name = "top_logprobs without logprobs", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .top_logprobs = 1 }, .want = .logprobs_required },
        .{ .name = "too many stop sequences", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .stop = .{ .sequences = too_many_stops } }, .want = .{ .too_many_stop_sequences = chat.max_stop_sequences + 1 } },
        .{ .name = "empty stop sequence", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .stop = .{ .sequences = &.{""} } }, .want = .empty_stop_sequence },
        .{ .name = "stream_options without stream", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .stream_options = .{} }, .want = .stream_options_require_stream },
        .{ .name = "tool without a name", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .tools = &unnamed_tools }, .want = .{ .tool_name_required = 0 } },
        .{ .name = "tool with a bad name", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .tools = &bad_name_tools }, .want = .{ .tool_name_invalid = 0 } },
        .{ .name = "duplicate tool names", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .tools = &duplicate_tools }, .want = .{ .tool_name_reused = "f" } },
        .{ .name = "required tool choice in thinking mode", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .tools = &tools, .tool_choice = .{ .mode = .required } }, .want = .tool_choice_required_in_thinking_mode },
        .{ .name = "named tool choice in thinking mode", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .tool_choice = .{ .function = "f" } }, .want = .tool_choice_function_in_thinking_mode },
        .{ .name = "bad named tool choice", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .thinking = .disabled, .tool_choice = .{ .function = "get weather" } }, .want = .{ .tool_choice_function_invalid = "get weather" } },
        .{ .name = "tool calling turn needs reasoning when tools are present", .request = .{ .model = deepseek.Model.flash, .messages = &unreasoned, .tools = &tools }, .want = .{ .reasoning_replay_required = 1 } },
        .{ .name = "bad user_id", .request = .{ .model = deepseek.Model.flash, .messages = &one_message, .user_id = "has space" }, .want = .user_id_invalid },
        .{ .name = "prefix on a message that is not last", .request = .{ .model = deepseek.Model.flash, .messages = &prefix_not_last }, .want = .prefix_only_on_last_message },
        .{ .name = "prefix without content", .request = .{ .model = deepseek.Model.flash, .messages = &prefix_without_content }, .want = .prefix_requires_content },
        .{ .name = "assistant without a content string is allowed", .request = .{ .model = deepseek.Model.flash, .messages = &assistant_without_content } },
        .{ .name = "empty tool result is allowed", .request = .{ .model = deepseek.Model.flash, .messages = &empty_tool_result } },
    };

    for (cases) |case| try expectValidation(case.name, case.request.validate(), case.want);
}

// ------------------------------------------------------------------- fim ---
//
// Contract tests for POST /completions, from https://api-docs.deepseek.com/api/create-completion
// and https://api-docs.deepseek.com/guides/fim_completion, which also sets the
// 4K output ceiling and the Beta root this endpoint lives under.

// The request body the reference page documents.
test "the documented FIM request body" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{
        .content_type = "application/json",
        .parts = &.{
            \\{"id":"x","object":"text_completion","choices":[]}
        },
    }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, true);
    defer client.deinit();

    const completion = try sendFim(&client, &.{
        .model = deepseek.Model.flash,
        .prompt = "def fib(a):",
        .suffix = "    return fib(a-1) + fib(a-2)",
        .max_tokens = 128,
        .temperature = 0.3,
        .top_p = 0.9,
        .stop = .{ .sequences = &.{ "\n\n", "```" } },
        .logprobs = 5,
    });
    defer completion.deinit();
    server.finish();
    try server.expectNoFailures();

    const recorded = server.recorded.items[0];
    try expectRequest(recorded, "/beta/completions");
    try testing.expectEqualStrings(
        \\{"model":"deepseek-flash","prompt":"def fib(a):","suffix":"    return fib(a-1) + fib(a-2)","logprobs":5,"max_tokens":128,"stop":["\n\n","```"],"temperature":0.3,"top_p":0.9}
    , recorded.body);
}

// The completion fields the reference page's response example carries,
// including the legacy log-probability report.
test "the documented FIM completion response" {
    const gpa = testing.allocator;
    const replies = [_]Reply{.{
        .content_type = "application/json",
        .parts = &.{
            \\{
            \\  "id": "1f633d8b",
            \\  "object": "text_completion",
            \\  "created": 1718345013,
            \\  "model": "deepseek-flash",
            \\  "system_fingerprint": "fp_a49d71b8a1",
            \\  "choices": [{
            \\    "finish_reason": "stop",
            \\    "index": 0,
            \\    "text": "    if a < 2:\n        return a\n",
            \\    "logprobs": {
            \\      "text_offset": [12, 15],
            \\      "token_logprobs": [-0.01, -0.2],
            \\      "tokens": ["    if", " a"],
            \\      "top_logprobs": [{"    if": -0.01}, {" a": -0.2}]
            \\    }
            \\  }],
            \\  "usage": {
            \\    "completion_tokens": 14,
            \\    "prompt_tokens": 9,
            \\    "total_tokens": 23,
            \\    "prompt_cache_hit_tokens": 0,
            \\    "prompt_cache_miss_tokens": 9,
            \\    "prompt_tokens_details": {"cached_tokens": 0}
            \\  }
            \\}
        },
    }};
    var server = try FakeServer.init(gpa, testing.io, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, true);
    defer client.deinit();

    const parsed = try sendFim(&client, &.{
        .model = deepseek.Model.flash,
        .prompt = "def fib(a):",
    });
    defer parsed.deinit();
    const completion = parsed.value;
    server.finish();
    try server.expectNoFailures();

    try testing.expectEqualStrings("1f633d8b", completion.id);
    try testing.expectEqualStrings("text_completion", completion.object);
    try testing.expectEqual(1718345013, completion.created);
    try testing.expectEqualStrings("fp_a49d71b8a1", completion.system_fingerprint);
    try testing.expectEqualStrings("    if a < 2:\n        return a\n", completion.text());

    const logprobs = completion.choices[0].logprobs.?;
    try testing.expectEqualStrings(fim.FinishReason.stop, completion.choices[0].finish_reason.?);
    try testing.expectEqual(2, logprobs.tokens.len);
    try testing.expectEqual(12, logprobs.text_offset[0]);
    try testing.expectEqual(-0.2, logprobs.token_logprobs[1]);
    try testing.expectEqual(-0.01, logprobs.top_logprobs[0].map.get("    if").?);
    try testing.expectEqual(14, completion.usage.?.completion_tokens);
}

// The streamed FIM shape the reference page documents: `text_completion`
// chunks whose `choices[].text` grows, the tokens billed on the last one, and
// the `data: [DONE]` sentinel. Collected, they add up to the whole text.
test "the documented FIM stream" {
    const gpa = testing.allocator;
    const events = [_][]const u8{
        \\{"id":"1f63","object":"text_completion","created":1718345013,"model":"deepseek-flash","system_fingerprint":"fp_a49","choices":[{"index":0,"text":"    if","finish_reason":null}]}
        ,
        \\{"id":"1f63","object":"text_completion","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"text":" a < 2:","finish_reason":null,"logprobs":{"text_offset":[4],"token_logprobs":[-0.01],"tokens":[" a"],"top_logprobs":[{" a":-0.01}]}}]}
        ,
        \\{"id":"1f63","object":"text_completion","created":1718345013,"model":"deepseek-flash","choices":[{"index":0,"text":"","finish_reason":"stop","logprobs":{"text_offset":[11],"token_logprobs":[-0.4],"tokens":[" <"],"top_logprobs":[{" <":-0.4}]}}],"usage":{"completion_tokens":3,"prompt_tokens":9,"total_tokens":12,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":9}}
        ,
    };
    var replies: [2]Reply = undefined;
    var server = try startStreamServer(gpa, &events, &replies);
    defer server.deinit();
    try server.start();

    var client = try testClient(gpa, &server, true);
    defer client.deinit();

    const request: fim.Request = .{ .model = deepseek.Model.flash, .prompt = "def fib(a):" };
    var stream = try streamFim(&client, &request);
    defer stream.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const first = (try stream.recv(a)).?;
    try testing.expectEqualStrings(fim.Object.text_completion, first.object);
    try testing.expectEqualStrings("    if", first.choices[0].text);

    const second = (try stream.recv(a)).?;
    try testing.expectEqualStrings(" a", second.choices[0].logprobs.?.tokens[0]);

    const last = (try stream.recv(a)).?;
    try testing.expectEqualStrings(fim.FinishReason.stop, last.choices[0].finish_reason.?);
    try testing.expectEqual(12, last.usage.?.total_tokens);
    try testing.expect(try stream.recv(a) == null);

    var second_stream = try streamFim(&client, &request);
    defer second_stream.deinit();
    var collected = try second_stream.collect(gpa);
    defer collected.deinit();
    try testing.expectEqualStrings("    if a < 2:", collected.value.text());
    try testing.expectEqual(11, collected.value.choices[0].logprobs.?.text_offset[1]);
    server.finish();
    try server.expectNoFailures();
}

// Every limit the reference page states for a FIM parameter.
test "the documented FIM parameter limits" {
    const gpa = testing.allocator;
    const too_many_stops = try gpa.alloc([]const u8, fim.max_stop_sequences + 1);
    defer gpa.free(too_many_stops);
    @memset(too_many_stops, "stop");

    const Case = struct {
        name: []const u8,
        request: fim.Request,
        want: ?fim.Invalid = null,
    };
    const cases = [_]Case{
        .{ .name = "minimal", .request = .{ .model = deepseek.Model.flash, .prompt = "def fib(a):" } },
        .{ .name = "echo alone", .request = .{ .model = deepseek.Model.flash, .prompt = "def fib(a):", .echo = true } },
        // The accepting side of the FIM limits, as in the chat table above.
        .{ .name = "logprobs at its floor", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .logprobs = 0 } },
        .{ .name = "logprobs at its ceiling", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .logprobs = fim.max_logprobs } },
        .{ .name = "max_tokens at its floor", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .max_tokens = 1 } },
        .{ .name = "max_tokens at its ceiling", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .max_tokens = fim.max_output_tokens } },
        .{ .name = "missing model", .request = .{ .model = "", .prompt = "x" }, .want = .model_required },
        .{ .name = "missing prompt", .request = .{ .model = deepseek.Model.flash, .prompt = "" }, .want = .prompt_required },
        .{ .name = "echo with suffix", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .echo = true, .suffix = "y" }, .want = .echo_with_suffix },
        .{ .name = "echo with logprobs", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .echo = true, .logprobs = 1 }, .want = .echo_with_logprobs },
        .{ .name = "logprobs above the ceiling", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .logprobs = fim.max_logprobs + 1 }, .want = .{ .logprobs_out_of_range = fim.max_logprobs + 1 } },
        .{ .name = "logprobs negative", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .logprobs = -1 }, .want = .{ .logprobs_out_of_range = -1 } },
        .{ .name = "max_tokens above the 4K ceiling", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .max_tokens = fim.max_output_tokens + 1 }, .want = .{ .max_tokens_out_of_range = fim.max_output_tokens + 1 } },
        .{ .name = "max_tokens zero", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .max_tokens = 0 }, .want = .{ .max_tokens_out_of_range = 0 } },
        .{ .name = "too many stop sequences", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .stop = .{ .sequences = too_many_stops } }, .want = .{ .too_many_stop_sequences = fim.max_stop_sequences + 1 } },
        .{ .name = "empty stop sequence", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .stop = .{ .sequences = &.{""} } }, .want = .empty_stop_sequence },
        .{ .name = "temperature out of range", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .temperature = 2.5 }, .want = .{ .temperature_out_of_range = 2.5 } },
        .{ .name = "top_p out of range", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .top_p = 0.0 }, .want = .{ .top_p_out_of_range = 0 } },
        .{ .name = "stream_options without stream", .request = .{ .model = deepseek.Model.flash, .prompt = "x", .stream_options = .{} }, .want = .stream_options_require_stream },
    };

    for (cases) |case| try expectValidation(case.name, case.request.validate(), case.want);
}

// The streamed replies need their parts and reply storage built by hand.
fn streamParts(gpa: Allocator, events: []const []const u8) ![]const []const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (parts.items) |part| gpa.free(part);
        parts.deinit(gpa);
    }
    try parts.append(gpa, try gpa.dupe(u8, ": keep-alive\n\n"));
    for (events) |event| {
        try parts.append(gpa, try std.fmt.allocPrint(gpa, "data: {s}\n\n", .{event}));
    }
    try parts.append(gpa, try gpa.dupe(u8, "data: [DONE]\n\n"));
    return parts.toOwnedSlice(gpa);
}

// Starts a server that streams `events` as server-sent events once per entry
// of `replies`, which holds the reply storage and must outlive the returned
// server.
fn startStreamServer(gpa: Allocator, events: []const []const u8, replies: []Reply) !FakeServer {
    const parts = try streamParts(gpa, events);
    errdefer {
        for (parts) |part| gpa.free(part);
        gpa.free(parts);
    }
    for (replies) |*reply| {
        reply.* = .{ .content_type = "text/event-stream", .chunked = true, .parts = parts };
    }
    var server = try FakeServer.init(gpa, testing.io, replies);
    server.owned_parts = parts;
    return server;
}

fn expectValidation(name: []const u8, result: anytype, want: ?Payload(@TypeOf(result), "err")) !void {
    switch (result) {
        .ok => if (want) |expected| {
            std.debug.print("case {s}: validate accepted an invalid request, want {any}\n", .{ name, expected });
            return error.TestUnexpectedResult;
        },
        .err => |invalid| {
            const expected = want orelse {
                std.debug.print("case {s}: validate = {f}, want success\n", .{ name, invalid });
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualDeep(expected, invalid);
        },
    }
}
