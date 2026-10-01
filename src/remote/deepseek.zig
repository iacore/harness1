//! DeepSeek API client.
//!
//! The shared layer is the authenticated client and its options, the error
//! envelope, the server-sent-event reader, and the usage, stop-sequence and
//! stream-option types. Two namespaces carry the endpoints:
//!
//!   * `chat` — POST /chat/completions
//!   * `fim`  — the Beta FIM completion endpoint POST /completions
//!
//! One `Client` serves both. Everything here uses `std`; HTTP and its
//! streaming response bodies come from `std.http.Client`, so no third-party
//! dependency is needed.
//!
//! Deciding points:
//!
//!   * Errors are bare names, and the API's own failures are values rather
//!     than errors: a call returns `Result(Success, Failure)` whose `.err`
//!     explains it, with the API's error envelope in `Failure.api`. A Zig
//!     error cannot carry that envelope, so its strings are the caller's to
//!     free with `APIError.deinit`.
//!   * Cancellation is the caller's `std.Io` concern: a request runs on the
//!     `Io` the client was built with, and no per-call handle is threaded
//!     through it.
//!   * The closed sets the API defines — `Message`, `Part`, `Content`,
//!     `ToolChoice` — are tagged unions, so combinations the API rejects are
//!     unrepresentable rather than merely invalid, and validation covers only
//!     what the type system cannot.
//!   * `Function.parameters` is pre-encoded JSON Schema text, written into the
//!     request verbatim.
//!   * A streamed chunk is parsed into an allocator the caller passes to
//!     `recv`; an arena reused per chunk makes the streaming loop
//!     allocation-stable. `collect` returns a `Collected` that owns everything
//!     it accumulated.
//!
//! The client, like `std.http.Client` underneath it, is safe for concurrent
//! use; individual `Response` values are not.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;

const json_encoder = @import("../root.zig").json_encoder;

/// The OpenAI-compatible API root.
pub const default_base_url = "https://api.deepseek.com";

/// Models served by the API.
pub const Model = struct {
    pub const flash = "deepseek-flash";
    pub const v4_pro = "deepseek-v4-pro";
};

/// Reports the tokens billed for a request. Both endpoints return it in the
/// same shape.
pub const Usage = struct {
    completion_tokens: i64 = 0,
    prompt_tokens: i64 = 0,
    total_tokens: i64 = 0,
    prompt_cache_hit_tokens: i64 = 0,
    prompt_cache_miss_tokens: i64 = 0,
    prompt_tokens_details: ?PromptTokensDetails = null,
    completion_tokens_details: ?CompletionTokensDetails = null,
};

/// Breaks the prompt tokens down by context-cache hits.
pub const PromptTokensDetails = struct {
    cached_tokens: i64 = 0,
};

/// Breaks the completion tokens down by reasoning.
pub const CompletionTokensDetails = struct {
    reasoning_tokens: i64 = 0,
};

/// Configures a streamed response.
pub const StreamOptions = struct {
    /// Puts a usage field on every chunk, null except on the last. The last
    /// chunk carries the usage of the whole request either way.
    include_usage: bool = false,

    pub const json = .{
        .fields = .{ .include_usage = .{ .skip_if_false = true } },
    };
};

/// The sequences at which generation stops, of which the API accepts up to 16.
/// Encodes as a single string when it holds one sequence and as an array
/// otherwise.
pub const Stop = struct {
    sequences: []const []const u8,

    pub const json = .{ .encode = encodeStop };
};

/// Writes one sequence as a string and several as an array, which is the shape
/// the API accepts.
fn encodeStop(e: *json_encoder.Encoder, stop: Stop) json_encoder.Error!void {
    if (stop.sequences.len == 1) return e.string(stop.sequences[0]);
    try e.beginArray();
    for (stop.sequences) |sequence| try e.string(sequence);
    return e.endArray();
}

/// How much of a failed response is read for the message.
const max_error_body = 64 << 10;

/// An error response from the API, as much of the envelope as was decodable.
pub const APIError = struct {
    /// HTTP status of the response.
    status_code: u16,
    /// The API's `error.message`, or the raw body when it was not an envelope.
    message: []u8 = &.{},
    /// The API's `error.type`.
    type: []u8 = &.{},
    /// The API's `error.param`.
    param: []u8 = &.{},
    /// The API's `error.code`, which it sends as a string or as a number.
    code: []u8 = &.{},

    /// Frees the strings. `allocator` must be the one the client was built
    /// with.
    pub fn deinit(self: *APIError, allocator: Allocator) void {
        allocator.free(self.message);
        allocator.free(self.type);
        allocator.free(self.param);
        allocator.free(self.code);
        self.* = undefined;
    }

    /// Renders the error, e.g.
    /// `deepseek: HTTP 429 rate_limit_error/429001: Rate limit reached`.
    pub fn format(self: APIError, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("deepseek: HTTP {d}", .{self.status_code});
        if (self.type.len != 0 and self.code.len != 0) {
            try writer.print(" {s}/{s}", .{ self.type, self.code });
        } else if (self.type.len != 0) {
            try writer.print(" {s}", .{self.type});
        } else if (self.code.len != 0) {
            try writer.print(" {s}", .{self.code});
        }
        if (self.param.len != 0) try writer.print(" (param {s})", .{self.param});
        if (self.message.len != 0) try writer.print(": {s}", .{self.message});
    }
};

/// What a call produced, or why it did not.
///
/// Failures that are part of the API's contract — a request the API would
/// reject, an error envelope, a misuse of the client — are values, so they can
/// carry the field, index or envelope that explains them. Failures that are
/// not — allocation, the socket, cancellation — stay Zig errors, which is what
/// keeps `try` and `defer` doing their job.
pub fn Result(comptime Success: type, comptime Failure: type) type {
    return union(enum) {
        ok: Success,
        err: Failure,

        /// The failure, when there is one.
        pub fn failure(self: @This()) ?Failure {
            return switch (self) {
                .ok => null,
                .err => |why| why,
            };
        }
    };
}

/// Accumulated stream result that owns every string in `value`.
pub fn Collected(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// Sends requests to the DeepSeek API.
pub const Client = struct {
    allocator: Allocator,
    io: Io,
    /// The key sent as `Bearer`; caller-owned, must outlive the client.
    api_key: []const u8,
    /// The API root without a trailing slash; caller-owned.
    base_url: []const u8,
    beta: bool,
    http_client: http.Client,

    pub const Options = struct {
        /// Another API root, such as a proxy. A trailing slash is optional.
        /// The default is `default_base_url`.
        base_url: ?[]const u8 = null,
        /// Routes requests through the Beta API root, which is the configured
        /// root with "/beta" appended.
        beta: bool = false,
    };

    pub const InitError = error{
        /// The key was empty or only whitespace.
        ApiKeyRequired,
    };

    /// Returns a client authenticated with `api_key`. The key and any
    /// configured base URL must outlive the client.
    pub fn init(allocator: Allocator, io: Io, api_key: []const u8, options: Options) InitError!Client {
        if (std.mem.trim(u8, api_key, " \t\r\n").len == 0) return error.ApiKeyRequired;
        const base = options.base_url orelse default_base_url;
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .base_url = std.mem.trimEnd(u8, base, "/"),
            .beta = options.beta,
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    /// Releases the connection pool. All responses must be deinited first.
    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.* = undefined;
    }

    /// Reports whether the client was built for the Beta API root.
    pub fn isBeta(self: *const Client) bool {
        return self.beta;
    }

    /// Sends the encoded `payload` as JSON to `path`, which is relative to the
    /// API root, and returns the response to a 2xx status. Any other status
    /// comes back as the API's error envelope.
    fn post(
        self: *Client,
        path: []const u8,
        payload: []const u8,
        stream: bool,
    ) !Result(*Response, APIError) {
        const gpa = self.allocator;
        const url = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
            self.base_url,
            if (self.beta) "/beta" else "",
            path,
        });
        defer gpa.free(url);
        const uri = try std.Uri.parse(url);

        const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{self.api_key});
        defer gpa.free(bearer);
        var headers: [3]http.Header = undefined;
        var count: usize = 0;
        headers[count] = .{ .name = "authorization", .value = bearer };
        count += 1;
        headers[count] = .{ .name = "content-type", .value = "application/json" };
        count += 1;
        if (stream) {
            headers[count] = .{ .name = "accept", .value = "text/event-stream" };
            count += 1;
        }

        const request = try gpa.create(http.Client.Request);
        errdefer gpa.destroy(request);
        request.* = try self.http_client.request(.POST, uri, .{
            .extra_headers = headers[0..count],
            // A redirect means the root is misconfigured; the API never
            // redirects a POST.
            .redirect_behavior = .not_allowed,
        });
        errdefer request.deinit();

        request.transfer_encoding = .{ .content_length = payload.len };
        var body = try request.sendBody(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try request.connection.?.flush();

        var head = try request.receiveHead(&.{});
        const status: u16 = @backingInt(head.head.status);
        if (status < 200 or status >= 300) {
            const envelope = try self.readApiError(&head);
            request.deinit();
            gpa.destroy(request);
            return .{ .err = envelope };
        }

        const response = try gpa.create(Response);
        errdefer gpa.destroy(response);
        const transfer_buffer = try gpa.alloc(u8, 4096);
        response.* = .{
            .allocator = gpa,
            .request = request,
            .head = head,
            .transfer_buffer = transfer_buffer,
        };
        return .{ .ok = response };
    }

    /// Reads the API's error envelope from a non-2xx response.
    fn readApiError(self: *Client, head: *http.Client.Response) !APIError {
        const gpa = self.allocator;
        const body = try gpa.alloc(u8, max_error_body);
        defer gpa.free(body);

        var transfer: [512]u8 = undefined;
        const reader = head.reader(&transfer);
        // A body that broke partway may still carry the API's explanation, so
        // whatever arrived is treated as the whole of it.
        const length = readUpTo(reader, body);
        const text = body[0..length];

        var out: APIError = .{ .status_code = @backingInt(head.head.status) };
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{
            .ignore_unknown_fields = true,
            // Keeps numbers as their source text: the API sends an error code
            // as a string or as a number.
            .parse_numbers = false,
        }) catch {
            out.message = try gpa.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
            return out;
        };
        defer parsed.deinit();

        const envelope = switch (parsed.value) {
            .object => |o| o.get("error") orelse return out,
            else => return out,
        };
        const fields = switch (envelope) {
            .object => |o| o,
            else => return out,
        };
        const message = stringField(fields, "message") orelse return out;
        if (message.len == 0) return out;

        // The strings are built one at a time, so a failure partway through
        // would strand the ones already taken.
        errdefer out.deinit(gpa);
        out.message = try gpa.dupe(u8, message);
        if (stringField(fields, "type")) |value| out.type = try gpa.dupe(u8, value);
        if (stringField(fields, "param")) |value| out.param = try gpa.dupe(u8, value);
        if (fields.get("code")) |code| {
            out.code = try gpa.dupe(u8, switch (code) {
                .string => |s| s,
                .number_string => |s| s,
                else => "",
            });
        }
        return out;
    }
};

/// A JSON object field that is a string, or null when it is absent or another
/// type.
fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Reads at most `buffer.len` bytes and returns how many are in `buffer`.
///
/// A body that breaks partway is not an error here: what arrived is what the
/// caller has, and a count taken from the buffer's length instead of from this
/// would hand out uninitialized memory, since an allocation does not zero it.
///
/// The body ending comes back as `error.EndOfStream` and as nothing else. A
/// read that returns zero has moved the reader along without handing bytes
/// over yet, which is what a reader that fills its own buffer first does, and
/// what every TLS connection's reader does; it is a round to come back for
/// rather than the end of anything.
fn readUpTo(reader: *Io.Reader, buffer: []u8) usize {
    var writer = Io.Writer.fixed(buffer);
    var length: usize = 0;
    while (length < buffer.len) {
        const n = reader.stream(&writer, .limited(buffer.len - length)) catch break;
        length += n;
    }
    return length;
}

// A reader may fill its own buffer and hand back nothing for a round, which is
// what the one behind every TLS connection does; `std.testing` ships a
// stand-in for exactly that. Its bytes take coming back for on the next round,
// so a read that treats a zero as the end of the body reads an empty one, and
// every HTTPS error envelope comes out with nothing in it but the status.
test "an error body is read through a reader that fills its own buffer" {
    const testing = std.testing;
    const body = "{\"error\":{\"message\":\"Rate limit reached\"}}";

    var input: Io.Reader = .fixed(body);
    var middle: [8]u8 = undefined;
    var indirect: testing.ReaderIndirect = .init(&input, &middle);

    var buffer: [128]u8 = undefined;
    const length = readUpTo(&indirect.interface, &buffer);
    try testing.expectEqualStrings(body, buffer[0..length]);
}

/// A response to a 2xx request whose body has not been read yet.
pub const Response = struct {
    allocator: Allocator,
    request: *http.Client.Request,
    head: http.Client.Response,
    transfer_buffer: []u8,

    /// Releases the connection. Anything read out of the body before this
    /// call stays valid; the body itself does not.
    pub fn deinit(self: *Response) void {
        const allocator = self.allocator;
        self.request.deinit();
        allocator.destroy(self.request);
        allocator.free(self.transfer_buffer);
        allocator.destroy(self);
    }

    /// The HTTP status of the response.
    pub fn status(self: *const Response) u16 {
        return @backingInt(self.head.head.status);
    }

    /// The response body as a streaming reader. May be called once.
    pub fn reader(self: *Response) *Io.Reader {
        return self.head.reader(self.transfer_buffer);
    }

    /// The error behind a failed read of `reader`, when there is one.
    pub fn bodyErr(self: *Response) ?http.Reader.BodyError {
        return self.head.bodyErr();
    }

    /// Reads the body as a JSON document of type `T`. The returned value owns
    /// its strings and must be deinited.
    pub fn parse(self: *Response, comptime T: type) !std.json.Parsed(T) {
        var source = std.json.Reader.init(self.allocator, self.reader());
        defer source.deinit();
        return std.json.parseFromTokenSource(T, self.allocator, &source, .{
            .ignore_unknown_fields = true,
        });
    }
};

/// Decodes the subset of the Server-Sent Events format that the API's
/// streaming endpoints emit: events of "data:" lines, ended by an empty line,
/// with comment lines such as ": keep-alive" and any other field ignored.
const SseReader = struct {
    allocator: Allocator,
    reader: *Io.Reader,
    /// The data of the event being decoded; valid until the next call.
    data: std.ArrayList(u8) = .empty,

    /// Returns the data of the next event, or null once the stream ends.
    /// Multiple data fields of one event are joined with a newline.
    fn next(self: *SseReader) !?[]const u8 {
        self.data.clearRetainingCapacity();
        var have_data = false;
        while (true) {
            const line = try self.reader.takeDelimiter('\n') orelse {
                // The last line of a body may arrive without its newline.
                return if (have_data) self.data.items else null;
            };
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) {
                if (have_data) return self.data.items;
                continue;
            }
            if (std.mem.cut(u8, trimmed, ":")) |field_and_value| {
                if (std.mem.eql(u8, field_and_value[0], "data")) {
                    const value = std.mem.cutPrefix(u8, field_and_value[1], " ") orelse field_and_value[1];
                    // An event with no payload carries nothing to dispatch.
                    if (value.len != 0) {
                        if (have_data) try self.data.append(self.allocator, '\n');
                        try self.data.appendSlice(self.allocator, value);
                        have_data = true;
                    }
                }
            }
        }
    }
};

/// The last event of a stream: generation is over.
const done_sentinel = "[DONE]";

/// A streamed response whose chunks are of type `Chunk`. `recv` returns the
/// chunks in order and null after the API's [DONE] sentinel, and `usage`
/// reports the tokens billed for the request, which arrive on the last chunk.
pub fn EventStream(comptime Chunk: type) type {
    comptime {
        if (!@hasField(Chunk, "usage")) @compileError("chunk type " ++ @typeName(Chunk) ++ " needs a usage field");
    }

    return struct {
        const Self = @This();

        /// Every error `recv` can end a stream with. Once one has been
        /// returned the stream is closed and every later call returns it
        /// again.
        pub const ReadError = error{
            /// The response was interrupted, or the body ended without [DONE].
            UnexpectedEof,
            /// An event did not decode as a chunk of this endpoint.
            MalformedChunk,
            /// The connection failed; see the response body's own error.
            ReadFailed,
            /// An event line did not fit in the reader's buffer.
            StreamTooLong,
            OutOfMemory,
        };

        allocator: Allocator,
        /// The response, owned by the stream once it is constructed.
        response: ?*Response,
        sse: SseReader,
        usage_value: ?Usage = null,
        failure: ?ReadError = null,
        finished: bool = false,

        /// Releases the connection. Anything already received stays valid
        /// only if it was parsed into the caller's own allocator.
        pub fn deinit(self: *Self) void {
            if (self.response) |response| response.deinit();
            self.sse.data.deinit(self.allocator);
            self.response = null;
        }

        /// Returns the next chunk of the response, parsed into `arena`, or
        /// null after the final event. `arena` may be reset once the chunk is
        /// no longer needed.
        pub fn recv(self: *Self, arena: Allocator) ReadError!?Chunk {
            if (self.failure) |err| return err;
            if (self.finished) return null;
            while (true) {
                const data = self.sse.next() catch |err| return self.fail(err);
                const event = data orelse return self.fail(error.UnexpectedEof);
                if (std.mem.eql(u8, std.mem.trim(u8, event, " \t\r\n"), done_sentinel)) {
                    self.finished = true;
                    return null;
                }
                const chunk = std.json.parseFromSliceLeaky(Chunk, arena, event, .{
                    .ignore_unknown_fields = true,
                    // The event buffer is reused, so strings must be copied
                    // into the caller's allocator.
                    .allocate = .alloc_always,
                }) catch |err| switch (err) {
                    error.OutOfMemory => |e| return self.fail(e),
                    else => return self.fail(error.MalformedChunk),
                };
                if (chunk.usage) |billed| self.usage_value = billed;
                return chunk;
            }
        }

        /// The tokens the API reported for the request, or null while they
        /// have not arrived.
        pub fn usage(self: *const Self) ?Usage {
            return self.usage_value;
        }

        /// Closes the stream and remembers `err` as its terminal state.
        fn fail(self: *Self, err: ReadError) ReadError {
            if (self.response) |response| response.deinit();
            self.response = null;
            self.failure = err;
            return err;
        }
    };
}

/// Wraps a `*Response` into a stream of `Chunk` events.
pub fn newEventStream(comptime Chunk: type, response: *Response) EventStream(Chunk) {
    return .{
        .allocator = response.allocator,
        .response = response,
        .sse = .{ .allocator = response.allocator, .reader = response.reader() },
    };
}

/// Chat Completions: POST /chat/completions, as documented at
/// https://api-docs.deepseek.com/api/create-chat-completion.
///
/// It covers the full request surface — messages with text, image and file
/// parts, thinking mode, tool calling, JSON output, logprobs, stop sequences,
/// streaming — the non-streaming and streaming response shapes, and the API's
/// error envelope.
///
/// Two features are restricted to the Beta API root and are rejected by `chat`
/// and `chatStream` unless the client was built with `beta = true`: Chat Prefix
/// Completion (`AssistantMessage.prefix`) and strict tool calls
/// (`Function.strict`).
pub const chat = struct {
    /// The endpoint's path, relative to the API root.
    pub const path = "/chat/completions";

    /// Roles of a request or response message.
    pub const Role = struct {
        pub const system = "system";
        pub const user = "user";
        pub const assistant = "assistant";
        pub const tool = "tool";
    };

    /// Object types of a completion and of a streamed chunk.
    pub const Object = struct {
        pub const completion = "chat.completion";
        pub const completion_chunk = "chat.completion.chunk";
    };

    /// `finish_reason` values.
    pub const FinishReason = struct {
        pub const stop = "stop";
        pub const length = "length";
        pub const content_filter = "content_filter";
        pub const tool_calls = "tool_calls";
        pub const insufficient_system_resource = "insufficient_system_resource";
        pub const aborted = "aborted";
    };

    /// The only tool type the API defines.
    pub const ToolType = struct {
        pub const function = "function";
    };

    /// Image detail levels accepted in an `image_url` content part.
    pub const ImageDetail = enum {
        low,
        high,
        original,
        auto,
    };

    /// Documented request limits.
    pub const max_output_tokens = 393216;
    pub const max_stop_sequences = 16;
    pub const max_top_logprobs = 20;
    pub const max_tool_name_len = 128;
    pub const max_user_id_len = 512;
    pub const max_image_url_len = 8192;

    /// One block of a message body: text, an image referenced by URL or data
    /// URL, or an image file.
    pub const Part = union(enum) {
        text: []const u8,
        image_url: ImageUrl,
        file: File,

        pub const json = .{
            .tag_key = "type",
            .fields = .{
                // A file part brings its own object, tag included.
                .file = .{ .bare = true },
            },
        };
    };

    /// An image referenced by http(s) URL or base64 data URL.
    pub const ImageUrl = struct {
        url: []const u8,
        detail: ?ImageDetail = null,
    };

    /// An image file: either one uploaded with the Files API, or one carried
    /// inline with the request. Exactly one of the two is representable.
    pub const File = union(enum) {
        /// An id of the form file-api-...
        id: struct { file_id: []const u8 },
        /// The image carried inline.
        data: FileData,

        pub const json = .{
            .tag_key = "type",
            .fields = .{
                .id = .{ .flatten = true, .key = "file" },
                .data = .{ .flatten = true, .key = "file" },
            },
        };
    };

    /// An image carried inline: a base64 data URL and its optional filename.
    pub const FileData = struct {
        data: []const u8,
        filename: ?[]const u8 = null,

        pub const json = .{ .fields = .{ .data = .{ .key = "file_data" } } };
    };

    /// Returns a text content part.
    pub fn textPart(content: []const u8) Part {
        return .{ .text = content };
    }

    /// Returns an image content part addressed by URL or data URL.
    pub fn imageUrlPart(url: []const u8, detail: ?ImageDetail) Part {
        return .{ .image_url = .{ .url = url, .detail = detail } };
    }

    /// Returns an image content part naming a file uploaded with the Files
    /// API.
    pub fn fileIdPart(id: []const u8) Part {
        return .{ .file = .{ .id = .{ .file_id = id } } };
    }

    /// Returns an image content part carrying the image inline.
    pub fn fileDataPart(data: []const u8, filename: ?[]const u8) Part {
        return .{ .file = .{ .data = .{ .data = data, .filename = filename } } };
    }

    /// The body of a message: plain text, or a list of content parts. It
    /// encodes as a JSON string when it is text and as an array otherwise,
    /// which is the shape the API expects. For an assistant turn that only
    /// calls tools, use the empty text, which encodes as "".
    pub const Content = union(enum) {
        text: []const u8,
        parts: []const Part,

        pub const json = .{ .encode = encodeContent };
    };

    /// Writes content the way the API expects it: one text part is a plain
    /// string, no parts at all is the empty string, and anything else is an
    /// array of parts.
    fn encodeContent(e: *json_encoder.Encoder, content: Content) json_encoder.Error!void {
        switch (content) {
            .text => |body| return e.string(body),
            .parts => |parts| {
                if (parts.len == 1 and parts[0] == .text) return e.string(parts[0].text);
                if (parts.len == 0) return e.string("");
                try e.beginArray();
                for (parts) |part| try json_encoder.encode(e, part);
                return e.endArray();
            },
        }
    }

    /// Returns text content, the common case.
    pub fn text(content: []const u8) Content {
        return .{ .text = content };
    }

    /// One entry of a conversation sent to the API. It is a closed set of four
    /// variants — because the API defines a different field set for each role,
    /// one type per role makes a tool_call_id on an assistant turn, or tool
    /// calls on a user turn, unrepresentable.
    pub const Message = union(enum) {
        system: SystemMessage,
        user: UserMessage,
        assistant: AssistantMessage,
        tool: ToolMessage,

        pub const json = .{
            .tag_key = "role",
            .fields = .{
                .system = .{ .flatten = true },
                .user = .{ .flatten = true },
                .assistant = .{ .flatten = true },
                .tool = .{ .flatten = true },
            },
        };

        /// The API role of the message.
        pub fn role(self: Message) []const u8 {
            return switch (self) {
                .system => Role.system,
                .user => Role.user,
                .assistant => Role.assistant,
                .tool => Role.tool,
            };
        }
    };

    /// The instruction that steers the model.
    pub const SystemMessage = struct {
        content: []const u8,
    };

    /// Input from the caller: text, and images referenced by URL or uploaded
    /// file.
    pub const UserMessage = struct {
        content: Content,
    };

    /// A previous model turn replayed into the conversation: its answer text,
    /// the tool calls it requested, and the chain of thought behind them.
    pub const AssistantMessage = struct {
        /// The answer text; the empty text when the turn only calls tools.
        content: Content = .{ .text = "" },

        /// The calls the model requested in this turn.
        tool_calls: ?[]const ToolCall = null,

        /// The chain of thought behind the turn. The API requires it on an
        /// assistant message that calls tools when the request carries tools,
        /// and it is the CoT input for a Beta Chat Prefix Completion.
        reasoning_content: ?[]const u8 = null,

        /// Marks a Beta Chat Prefix Completion: the model must start its
        /// answer with `content`. Only valid on the last message.
        prefix: ?bool = null,

        pub const json = .{
            .fields = .{
                .tool_calls = .{ .skip_if_empty = true },
                .reasoning_content = .{ .skip_if_empty = true },
                .prefix = .{ .skip_if_false = true },
            },
        };
    };

    /// The result of a tool call, answering one assistant tool call by id.
    pub const ToolMessage = struct {
        content: []const u8,
        tool_call_id: []const u8,
    };

    /// Returns a tool message answering the tool call with the given id.
    pub fn toolResult(tool_call_id: []const u8, content: []const u8) ToolMessage {
        return .{ .tool_call_id = tool_call_id, .content = content };
    }

    /// A function the model may call. "function" is the only tool type the API
    /// defines, so the field has no default other than itself.
    pub const Tool = struct {
        type: []const u8 = ToolType.function,
        function: Function = .{},
    };

    /// The declaration of a callable function.
    pub const Function = struct {
        name: []const u8 = "",

        description: ?[]const u8 = null,

        /// A JSON Schema object, already encoded as JSON text and written into
        /// the request verbatim. Leaving it null declares an empty parameter
        /// list.
        parameters: ?json_encoder.Raw = null,

        /// Enables Beta strict mode: the arguments must validate against
        /// `parameters`, which must set additionalProperties to false and list
        /// every property as required. Needs the Beta API root.
        strict: ?bool = null,

        pub const json = .{
            .fields = .{
                .description = .{ .skip_if_empty = true },
                .parameters = .{ .skip_if_empty = true },
                .strict = .{ .skip_if_false = true },
            },
        };
    };

    /// A function call requested by the model; in a streamed delta it is a
    /// fragment of one, identified by `index`.
    pub const ToolCall = struct {
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        function: FunctionCall = .{},

        /// Which call this fragment belongs to. Belongs to the streamed deltas
        /// it was decoded from, and is not part of a request.
        index: ?i64 = null,

        pub const json = .{
            .fields = .{
                .id = .{ .skip_if_empty = true },
                .type = .{ .skip_if_empty = true },
                .index = .{ .skip = true },
            },
        };
    };

    /// The name of a tool and its arguments, JSON-encoded as a string.
    pub const FunctionCall = struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
    };

    /// Selects the tool the model must call.
    pub const ToolChoice = union(enum) {
        /// Forbids tool calls, or lets the model decide, or forces it to call
        /// a tool.
        mode: Mode,
        /// Forces the model to call the named function. Not supported in
        /// thinking mode.
        function: []const u8,

        pub const Mode = enum {
            /// Forbids tool calls.
            none,
            /// Lets the model decide between answering and calling a tool.
            auto,
            /// Forces the model to call one or more tools. Not supported in
            /// thinking mode.
            required,
        };

        pub const json = .{ .encode = encodeToolChoice };
    };

    /// Writes a bare mode as a string and a named function as the object the
    /// API expects.
    fn encodeToolChoice(e: *json_encoder.Encoder, choice: ToolChoice) json_encoder.Error!void {
        switch (choice) {
            .mode => |mode| return e.string(@tagName(mode)),
            .function => |name| {
                try e.beginObject();
                try e.key("type");
                try e.string(ToolType.function);
                try e.key("function");
                try e.beginObject();
                try e.key("name");
                try e.string(name);
                try e.endObject();
                return e.endObject();
            },
        }
    }

    /// Toggles the chain of thought, which is on by default.
    pub const Thinking = enum {
        enabled,
        disabled,

        pub const json = .{ .tag_key = "type" };
    };

    /// The thinking effort. `minimal`, `medium`, `xhigh` and `ultra` are
    /// accepted for compatibility with other clients and mapped by the API:
    /// minimal to low, medium and xhigh to high, ultra to max.
    pub const ReasoningEffort = enum {
        none,
        minimal,
        low,
        medium,
        high,
        xhigh,
        ultra,
        max,
    };

    /// Asks for plain text or for a guaranteed-valid JSON object.
    pub const ResponseFormat = enum {
        text,
        json_object,

        pub const json = .{ .tag_key = "type" };
    };

    /// The body of POST /chat/completions. Optional parameters are optional
    /// fields so that "unset" stays distinguishable from a zero value, which
    /// matters for the ones with a server-side default.
    pub const Request = struct {
        /// `Model.flash` or `Model.v4_pro`. Required.
        model: []const u8,

        /// The conversation so far. Required; the API accepts one or more.
        messages: []const Message,

        /// Toggles the chain of thought, which is enabled by default.
        thinking: ?Thinking = null,

        /// Selects the thinking effort. `.none` disables thinking mode;
        /// `.high` is the default. Has no effect in non-thinking mode.
        reasoning_effort: ?ReasoningEffort = null,

        /// Bounds the generated tokens, reasoning included. Defaults to 8192
        /// in non-thinking mode, 65536 in thinking mode, 131072 at
        /// `.max`.
        max_tokens: ?i64 = null,

        /// Asks for plain text or for a JSON object.
        response_format: ?ResponseFormat = null,

        /// Up to `max_stop_sequences` sequences at which generation stops.
        stop: ?Stop = null,

        /// Asks for server-sent events instead of one JSON body. `chat`
        /// requires it to be false; `chatStream` sets it.
        stream: ?bool = null,

        /// Configures a streamed response and requires `stream`.
        stream_options: ?StreamOptions = null,

        /// Samples between 0 and 2 and has no effect in thinking mode.
        temperature: ?f64 = null,

        /// Nucleus sampling. It only applies in thinking mode, where the
        /// effective range is 0.95 to 1.
        top_p: ?f64 = null,

        /// The functions the model may call.
        tools: ?[]const Tool = null,

        /// Constrains tool calling.
        tool_choice: ?ToolChoice = null,

        /// Asks for the log probabilities of the generated tokens.
        logprobs: ?bool = null,

        /// How many alternatives to report per token position, from 0 to
        /// `max_top_logprobs`. Requires `logprobs`.
        top_logprobs: ?i64 = null,

        /// Identifies the end user for abuse review, cache isolation and
        /// scheduling. Do not put private data in it.
        user_id: ?[]const u8 = null,

        pub const json = .{
            .fields = .{
                .tools = .{ .skip_if_empty = true },
                .user_id = .{ .skip_if_empty = true },
            },
        };

        /// Reports whether the request satisfies the constraints the API
        /// documents for POST /chat/completions, so that a request the API
        /// would reject is caught before it is sent. `send` and `sendStream`
        /// call it, so callers rarely need it. Only documented constraints are
        /// checked; whether the model accepts a schema, for instance, is left
        /// to the server.
        pub fn validate(self: *const Request) Result(void, Invalid) {
            if (self.check(self.stream orelse false)) |invalid| return .{ .err = invalid };
            return .{ .ok = {} };
        }

        /// The first constraint the request breaks, or null when it breaks
        /// none. `streaming` is whether the call being made streams, since
        /// stream_options is only valid there.
        fn check(self: *const Request, streaming: bool) ?Invalid {
            if (std.mem.trim(u8, self.model, " \t\r\n").len == 0) return .model_required;
            if (self.messages.len == 0) return .messages_required;

            const last = self.messages.len - 1;
            // The tool call ids the conversation has defined so far, so that a
            // tool result can be checked against the call it answers.
            var calls: std.StringHashMapUnmanaged(void) = .empty;
            defer calls.deinit(std.heap.page_allocator);
            for (self.messages, 0..) |message, i| {
                if (checkMessage(message, i, last, &calls)) |invalid| return invalid;
            }

            if (self.max_tokens) |max_tokens| {
                if (max_tokens < 1 or max_tokens > max_output_tokens) {
                    return .{ .max_tokens_out_of_range = max_tokens };
                }
            }
            if (self.temperature) |temperature| {
                if (!(temperature >= 0 and temperature <= 2)) {
                    return .{ .temperature_out_of_range = temperature };
                }
            }
            if (self.top_p) |top_p| {
                if (!(top_p > 0 and top_p <= 1)) return .{ .top_p_out_of_range = top_p };
            }
            if (self.top_logprobs) |top_logprobs| {
                if (top_logprobs < 0 or top_logprobs > max_top_logprobs) {
                    return .{ .top_logprobs_out_of_range = top_logprobs };
                }
                if (self.logprobs == null or !self.logprobs.?) return .logprobs_required;
            }
            if (self.stop) |stop| {
                if (stop.sequences.len > max_stop_sequences) {
                    return .{ .too_many_stop_sequences = stop.sequences.len };
                }
                for (stop.sequences) |sequence| {
                    if (sequence.len == 0) return .empty_stop_sequence;
                }
            }
            if (self.stream_options != null and !streaming) return .stream_options_require_stream;
            if (checkTools(self.tools)) |invalid| return invalid;
            if (self.tool_choice) |choice| {
                if (checkToolChoice(choice, self.thinkingMode())) |invalid| return invalid;
            }
            // In thinking mode the API needs the chain of thought of every
            // tool-calling assistant turn replayed, which is what makes the
            // model's next call consistent with the call it answers.
            if (self.thinkingMode() and self.tools != null and self.tools.?.len != 0) {
                for (self.messages, 0..) |message, i| {
                    switch (message) {
                        .assistant => |assistant| {
                            const calls_to_replay = assistant.tool_calls orelse continue;
                            if (calls_to_replay.len == 0) continue;
                            const reasoning = assistant.reasoning_content orelse "";
                            if (reasoning.len == 0) return .{ .reasoning_replay_required = i };
                        },
                        else => {},
                    }
                }
            }
            if (self.user_id) |user_id| {
                if (user_id.len != 0) {
                    if (user_id.len > max_user_id_len or !isToolName(user_id)) return .user_id_invalid;
                }
            }
            return null;
        }

        /// Reports whether the request runs in thinking mode, which is the
        /// default and is turned off either by thinking.type or by
        /// reasoning_effort.
        fn thinkingMode(self: *const Request) bool {
            if (self.thinking) |t| return t != .disabled;
            if (self.reasoning_effort) |effort| return effort != .none;
            return true;
        }

        /// The Beta requirement the request brings, or null when it needs no
        /// more than the plain root. `beta` is whether the client is built for
        /// the Beta root.
        fn checkBeta(self: *const Request, beta: bool) ?Failure {
            if (beta) return null;
            if (self.tools) |tools| {
                for (tools) |tool| {
                    if (tool.function.strict orelse false) return .strict_tools_require_beta;
                }
            }
            if (self.messages.len != 0) {
                switch (self.messages[self.messages.len - 1]) {
                    .assistant => |assistant| {
                        if (assistant.prefix orelse false) return .prefix_completion_requires_beta;
                    },
                    else => {},
                }
            }
            return null;
        }
    };

    /// Checks one message against its role's constraints. `calls` carries the
    /// tool call ids defined so far; an assistant message adds to it and a
    /// tool message must already be in it.
    fn checkMessage(
        message: Message,
        index: usize,
        last: usize,
        calls: *std.StringHashMapUnmanaged(void),
    ) ?Invalid {
        switch (message) {
            .system => |system| {
                if (system.content.len == 0) return .{ .message_content_required = index };
            },
            .user => |user| {
                if (contentLength(user.content) == 0) return .{ .message_content_required = index };
                if (checkParts(user.content, Role.user)) |invalid| return invalid;
            },
            .assistant => |assistant| {
                if (checkParts(assistant.content, Role.assistant)) |invalid| return invalid;
                if (assistant.prefix orelse false) {
                    if (index != last) return .prefix_only_on_last_message;
                    if (contentLength(assistant.content) == 0) return .prefix_requires_content;
                }
                for (assistant.tool_calls orelse &.{}) |call| {
                    if (checkToolCall(call, calls, index)) |invalid| return invalid;
                }
            },
            .tool => |tool| {
                if (tool.tool_call_id.len == 0) return .{ .tool_call_id_required = index };
                if (!calls.contains(tool.tool_call_id)) {
                    return .{ .tool_call_id_unknown = tool.tool_call_id };
                }
            },
        }
        return null;
    }

    fn checkParts(content: Content, role: []const u8) ?Invalid {
        const parts = switch (content) {
            .text => return null,
            .parts => |parts| parts,
        };
        for (parts, 0..) |part, i| {
            switch (part) {
                .text => |body| {
                    if (body.len == 0) return .{ .text_part_required = i };
                },
                .image_url => |image_url| {
                    if (!std.mem.eql(u8, role, Role.user)) {
                        return .{ .part_not_allowed_for_role = i };
                    }
                    if (image_url.url.len == 0) return .{ .image_url_required = i };
                    if (image_url.url.len > max_image_url_len) {
                        return .{ .image_url_too_long = image_url.url.len };
                    }
                },
                .file => {
                    if (!std.mem.eql(u8, role, Role.user)) {
                        return .{ .part_not_allowed_for_role = i };
                    }
                },
            }
        }
        return null;
    }

    /// Checks one tool call and records its id, so that a later tool message
    /// can be matched to it and a duplicate id is caught.
    fn checkToolCall(
        call: ToolCall,
        calls: *std.StringHashMapUnmanaged(void),
        index: usize,
    ) ?Invalid {
        const id = call.id orelse "";
        if (id.len == 0) return .{ .tool_call_id_required = index };
        const kind = call.type orelse "";
        if (!std.mem.eql(u8, kind, ToolType.function)) return .{ .tool_call_type_unsupported = kind };
        if (call.function.name.len == 0) return .{ .tool_call_name_required = index };
        if (calls.contains(id)) return .{ .tool_call_id_reused = id };
        calls.put(std.heap.page_allocator, id, {}) catch return .{ .tool_call_id_reused = id };
        return null;
    }

    fn checkTools(tools: ?[]const Tool) ?Invalid {
        const list = tools orelse return null;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(std.heap.page_allocator);
        for (list, 0..) |tool, i| {
            const name = tool.function.name;
            if (name.len == 0) return .{ .tool_name_required = i };
            if (name.len > max_tool_name_len or !isToolName(name)) {
                return .{ .tool_name_invalid = i };
            }
            if (seen.contains(name)) return .{ .tool_name_reused = name };
            seen.put(std.heap.page_allocator, name, {}) catch return .{ .tool_name_reused = name };
        }
        return null;
    }

    fn checkToolChoice(choice: ToolChoice, thinking: bool) ?Invalid {
        switch (choice) {
            .function => |name| {
                if (name.len > max_tool_name_len or !isToolName(name)) {
                    return .{ .tool_choice_function_invalid = name };
                }
                if (thinking) return .tool_choice_function_in_thinking_mode;
            },
            .mode => |mode| {
                if (mode == .required and thinking) return .tool_choice_required_in_thinking_mode;
            },
        }
        return null;
    }

    /// A constraint a request breaks, with the field, index or value that
    /// explains it.
    pub const Invalid = union(enum) {
        model_required,
        messages_required,
        /// The index of the message whose content is missing.
        message_content_required: usize,
        /// The index of the empty text part.
        text_part_required: usize,
        /// The index of the image part with no URL.
        image_url_required: usize,
        /// The length of an over-long image URL.
        image_url_too_long: usize,
        /// The index of a part the message's role does not accept.
        part_not_allowed_for_role: usize,
        prefix_only_on_last_message,
        prefix_requires_content,
        /// The index of the tool call with no id.
        tool_call_id_required: usize,
        /// The id no earlier assistant tool call defined.
        tool_call_id_unknown: []const u8,
        /// The id defined more than once.
        tool_call_id_reused: []const u8,
        /// The tool call type the API does not define.
        tool_call_type_unsupported: []const u8,
        /// The index of the tool call with no function name.
        tool_call_name_required: usize,
        max_tokens_out_of_range: i64,
        temperature_out_of_range: f64,
        top_p_out_of_range: f64,
        top_logprobs_out_of_range: i64,
        logprobs_required,
        /// How many sequences were given, against a limit of 16.
        too_many_stop_sequences: usize,
        empty_stop_sequence,
        stream_options_require_stream,
        /// The index of the tool with no name.
        tool_name_required: usize,
        /// The index of the tool whose name is not the API's shape.
        tool_name_invalid: usize,
        /// The name defined more than once.
        tool_name_reused: []const u8,
        /// The named function that is not the API's shape.
        tool_choice_function_invalid: []const u8,
        tool_choice_function_in_thinking_mode,
        tool_choice_required_in_thinking_mode,
        /// The index of the tool-calling turn with no chain of thought.
        reasoning_replay_required: usize,
        user_id_invalid,

        /// Renders the failure the way the API documents the constraint.
        pub fn format(self: Invalid, writer: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .model_required => try writer.writeAll("model is required\n"),
                .messages_required => try writer.writeAll("at least one message is required"),
                .message_content_required => |index| try writer.print("messages[{d}]: content is required", .{index}),
                .text_part_required => |index| try writer.print("content[{d}]: text is required for text parts", .{index}),
                .image_url_required => |index| try writer.print("content[{d}]: image_url.url is required", .{index}),
                .image_url_too_long => |length| try writer.print("image_url.url must be at most {d} characters, got {d}", .{ max_image_url_len, length }),
                .part_not_allowed_for_role => |index| try writer.print("content[{d}]: this part is only allowed in user messages", .{index}),
                .prefix_only_on_last_message => try writer.writeAll("prefix is only allowed on the last message"),
                .prefix_requires_content => try writer.writeAll("prefix requires content"),
                .tool_call_id_required => |index| try writer.print("messages[{d}]: tool_call_id is required", .{index}),
                .tool_call_id_unknown => |id| try writer.print("tool_call_id \"{s}\" does not match an earlier assistant tool call", .{id}),
                .tool_call_id_reused => |id| try writer.print("tool call id \"{s}\" is used more than once", .{id}),
                .tool_call_type_unsupported => |kind| try writer.print("tool call type \"{s}\" is not supported", .{kind}),
                .tool_call_name_required => |index| try writer.print("messages[{d}]: a tool call needs function.name", .{index}),
                .max_tokens_out_of_range => |value| try writer.print("max_tokens must be between 1 and {d}, got {d}", .{ max_output_tokens, value }),
                .temperature_out_of_range => |value| try writer.print("temperature must be between 0 and 2, got {d}", .{value}),
                .top_p_out_of_range => |value| try writer.print("top_p must be greater than 0 and at most 1, got {d}", .{value}),
                .top_logprobs_out_of_range => |value| try writer.print("top_logprobs must be between 0 and {d}, got {d}", .{ max_top_logprobs, value }),
                .logprobs_required => try writer.writeAll("logprobs must be true when top_logprobs is set"),
                .too_many_stop_sequences => |count| try writer.print("stop accepts at most {d} sequences, got {d}", .{ max_stop_sequences, count }),
                .empty_stop_sequence => try writer.writeAll("stop sequences must not be empty"),
                .stream_options_require_stream => try writer.writeAll("stream_options requires stream"),
                .tool_name_required => |index| try writer.print("tools[{d}].function.name is required", .{index}),
                .tool_name_invalid => |index| try writer.print("tools[{d}].function.name must be at most {d} characters of [a-zA-Z0-9_-]", .{ index, max_tool_name_len }),
                .tool_name_reused => |name| try writer.print("tools.function.name \"{s}\" is used more than once", .{name}),
                .tool_choice_function_invalid => |name| try writer.print("tool_choice function \"{s}\" must be at most {d} characters of [a-zA-Z0-9_-]", .{ name, max_tool_name_len }),
                .tool_choice_function_in_thinking_mode => try writer.writeAll("naming a function in tool_choice is not supported in thinking mode"),
                .tool_choice_required_in_thinking_mode => try writer.writeAll("tool_choice \"required\" is not supported in thinking mode"),
                .reasoning_replay_required => |index| try writer.print("messages[{d}]: reasoning_content is required on an assistant message that calls tools", .{index}),
                .user_id_invalid => try writer.print("user_id must be at most {d} characters of [a-zA-Z0-9_-]", .{max_user_id_len}),
            }
        }
    };

    /// What a chat call failed with, when it is part of the API's contract
    /// rather than an allocation or a socket.
    pub const Failure = union(enum) {
        /// The request breaks a documented constraint; see `Invalid.format`.
        invalid: Invalid,
        /// The API answered with an error envelope.
        api: APIError,
        /// The request asked for streaming; call `sendStream` instead.
        stream_requested,
        /// Strict tool calls need a client built with `beta = true`.
        strict_tools_require_beta,
        /// Chat prefix completion needs a client built with `beta = true`.
        prefix_completion_requires_beta,

        pub fn format(self: Failure, writer: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .invalid => |invalid| try invalid.format(writer),
                .api => |envelope| try envelope.format(writer),
                .stream_requested => try writer.writeAll("Request.stream is true; use sendStream"),
                .strict_tools_require_beta => try writer.writeAll("strict tool calls need the Beta API root; build the client with beta = true"),
                .prefix_completion_requires_beta => try writer.writeAll("chat prefix completion needs the Beta API root; build the client with beta = true"),
            }
        }
    };

    /// The length of the content of a message, in parts.
    fn contentLength(content: Content) usize {
        return switch (content) {
            .text => |body| if (body.len == 0) 0 else 1,
            .parts => |parts| parts.len,
        };
    }

    /// `^[a-zA-Z0-9_-]+$`.
    fn isToolName(name: []const u8) bool {
        if (name.len == 0) return false;
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }
        return true;
    }

    /// `^[a-zA-Z0-9\-_]+$`.
    fn isUserId(user_id: []const u8) bool {
        return isToolName(user_id);
    }

    /// A non-streaming response, and the result of collecting a stream.
    pub const Completion = struct {
        id: []const u8 = "",
        object: []const u8 = "",
        created: i64 = 0,
        model: []const u8 = "",
        system_fingerprint: []const u8 = "",
        choices: []const Choice = &.{},
        usage: ?Usage = null,

        /// The message of the first choice, or a zero message when the
        /// response carries no choice.
        pub fn message(self: *const Completion) GeneratedMessage {
            if (self.choices.len == 0) return .{};
            return self.choices[0].message;
        }
    };

    /// One completed alternative.
    pub const Choice = struct {
        index: i64 = 0,
        finish_reason: ?[]const u8 = null,
        message: GeneratedMessage = .{},
        logprobs: ?Logprobs = null,
    };

    /// A message generated by the model. `content` is empty when the API
    /// answered with null or with an empty string.
    pub const GeneratedMessage = struct {
        role: []const u8 = "",
        content: []const u8 = "",
        reasoning_content: []const u8 = "",
        tool_calls: []const ToolCall = &.{},

        /// Converts the generated message into an assistant turn to replay in
        /// the next request, keeping the chain of thought and the tool calls,
        /// which the API requires to be sent back on every tool-calling turn.
        pub fn toAssistant(self: GeneratedMessage) AssistantMessage {
            return .{
                .content = text(self.content),
                .reasoning_content = if (self.reasoning_content.len == 0) null else self.reasoning_content,
                .tool_calls = if (self.tool_calls.len == 0) null else self.tool_calls,
            };
        }
    };

    /// The log probabilities of the generated tokens. In thinking mode the
    /// chain of thought has its own list.
    pub const Logprobs = struct {
        content: []const TokenLogprob = &.{},
        reasoning_content: []const TokenLogprob = &.{},
    };

    /// The log probability of one generated token.
    pub const TokenLogprob = struct {
        token: []const u8 = "",
        logprob: f64 = 0,
        /// Null when the API did not report the token's bytes.
        bytes: ?[]const i64 = null,
        /// Null at the positions the API does not report alternatives for.
        top_logprobs: ?[]const TopLogprob = null,
    };

    /// One of the most likely alternatives at a token position.
    pub const TopLogprob = struct {
        token: []const u8 = "",
        logprob: f64 = 0,
        /// Null when the API did not report the token's bytes.
        bytes: ?[]const i64 = null,
    };

    /// One event of a streamed response.
    pub const Chunk = struct {
        id: []const u8 = "",
        object: []const u8 = "",
        created: i64 = 0,
        model: []const u8 = "",
        system_fingerprint: []const u8 = "",
        choices: []const ChunkChoice = &.{},
        usage: ?Usage = null,
    };

    /// The increment of one choice within a chunk.
    pub const ChunkChoice = struct {
        index: i64 = 0,
        delta: Delta = .{},
        /// Null until the model stops.
        finish_reason: ?[]const u8 = null,
        logprobs: ?Logprobs = null,
    };

    /// The content a chunk adds. Tool call fragments carry an index; the first
    /// fragment of each call also carries id, type and the function name, and
    /// later fragments only extend the arguments.
    pub const Delta = struct {
        role: []const u8 = "",
        content: []const u8 = "",
        reasoning_content: []const u8 = "",
        tool_calls: []const ToolCall = &.{},
    };

    /// Sends a non-streaming request. A request that asks for streaming is
    /// refused; use `sendStream`.
    pub fn send(
        client: *Client,
        request: *const Request,
    ) !Result(std.json.Parsed(Completion), Failure) {
        if (request.stream orelse false) return .{ .err = .stream_requested };
        if (request.checkBeta(client.beta)) |failure| return .{ .err = failure };
        if (request.check(false)) |invalid| return .{ .err = .{ .invalid = invalid } };
        const payload = try encode(client.allocator, request);
        defer client.allocator.free(payload);
        const response = switch (try client.post(path, payload, false)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = .{ .api = envelope } },
        };
        defer response.deinit();
        return .{ .ok = try response.parse(Completion) };
    }

    /// Sends a streaming request and returns the event stream. The request is
    /// sent with stream set to true whatever `request.stream` says, and the
    /// caller must deinit the returned stream, though reading it to its end
    /// leaves nothing to release but the connection.
    pub fn sendStream(
        client: *Client,
        request: *const Request,
    ) !Result(Stream, Failure) {
        if (request.checkBeta(client.beta)) |failure| return .{ .err = failure };
        if (request.check(true)) |invalid| return .{ .err = .{ .invalid = invalid } };
        var body = request.*;
        body.stream = true;
        const payload = try encode(client.allocator, &body);
        defer client.allocator.free(payload);
        const response = switch (try client.post(path, payload, true)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = .{ .api = envelope } },
        };
        return .{ .ok = .{ .inner = newEventStream(Chunk, response) } };
    }

    /// Encodes a request body with the client's allocator.
    fn encode(allocator: Allocator, request: *const Request) ![]u8 {
        return json_encoder.stringify(allocator, request.*);
    }

    /// A streamed Chat Completions response. `recv` returns the chunks in
    /// order, `usage` the tokens billed for the request, and `collect`
    /// assembles the whole response instead.
    pub const Stream = struct {
        inner: EventStream(Chunk),

        /// Releases the connection.
        pub fn deinit(self: *Stream) void {
            self.inner.deinit();
        }

        /// Returns the next chunk of the response, or null after the final
        /// event. `arena` may be reset once the chunk is no longer needed.
        pub fn recv(self: *Stream, arena: Allocator) EventStream(Chunk).ReadError!?Chunk {
            return self.inner.recv(arena);
        }

        /// The tokens the API reported for the request, or null while they
        /// have not arrived.
        pub fn usage(self: *const Stream) ?Usage {
            return self.inner.usage();
        }

        /// Reads the rest of the stream and assembles the deltas into the same
        /// completion `send` returns, including the content, the chain of
        /// thought, the tool calls whose arguments arrive in fragments, the
        /// log probabilities and the usage.
        pub fn collect(self: *Stream, allocator: Allocator) !Collected(Completion) {
            var collected: Collected(Completion) = .{
                .arena = .init(allocator),
                .value = .{ .object = Object.completion },
            };
            errdefer collected.arena.deinit();
            const arena = collected.arena.allocator();

            var accumulators: std.ArrayListUnmanaged(Accumulator) = .empty;
            while (try self.recv(arena)) |chunk| {
                if (collected.value.id.len == 0) {
                    collected.value.id = chunk.id;
                    collected.value.created = chunk.created;
                    collected.value.model = chunk.model;
                    collected.value.system_fingerprint = chunk.system_fingerprint;
                }
                for (chunk.choices) |choice| {
                    const slot = try accumulatorFor(arena, &accumulators, choice.index);
                    try accumulators.items[slot].merge(arena, choice);
                }
            }
            collected.value.usage = self.usage();

            std.mem.sort(Accumulator, accumulators.items, {}, byIndex);
            const choices = try arena.alloc(Choice, accumulators.items.len);
            for (accumulators.items, choices) |*accumulator, *choice| {
                choice.* = try accumulator.build(arena);
            }
            collected.value.choices = choices;
            return collected;
        }
    };

    fn byIndex(_: void, a: Accumulator, b: Accumulator) bool {
        return a.index < b.index;
    }

    fn accumulatorFor(
        arena: Allocator,
        accumulators: *std.ArrayListUnmanaged(Accumulator),
        index: i64,
    ) !usize {
        for (accumulators.items, 0..) |accumulator, i| {
            if (accumulator.index == index) return i;
        }
        try accumulators.append(arena, .{
            .index = index,
            .content = .empty,
            .reasoning_content = .empty,
            .tool_calls = .empty,
            .tool_arguments = .empty,
        });
        return accumulators.items.len - 1;
    }

    /// Assembles the deltas of one choice.
    const Accumulator = struct {
        index: i64,
        role: []const u8 = "",
        content: std.ArrayListUnmanaged(u8),
        reasoning_content: std.ArrayListUnmanaged(u8),
        finish_reason: []const u8 = "",
        /// Tool calls in the order they were first seen, with their arguments
        /// accumulated separately since they arrive in fragments.
        tool_calls: std.ArrayListUnmanaged(ToolCall),
        tool_arguments: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)),
        logprobs_content: ?std.ArrayListUnmanaged(TokenLogprob) = null,
        logprobs_reasoning: ?std.ArrayListUnmanaged(TokenLogprob) = null,

        fn merge(self: *Accumulator, arena: Allocator, choice: ChunkChoice) !void {
            const delta = choice.delta;
            if (delta.role.len != 0) self.role = try arena.dupe(u8, delta.role);
            try self.content.appendSlice(arena, delta.content);
            try self.reasoning_content.appendSlice(arena, delta.reasoning_content);
            for (delta.tool_calls) |call| {
                const slot = try self.slotFor(arena, call.index orelse 0);
                const target = &self.tool_calls.items[slot];
                if (call.id) |id| {
                    if (id.len != 0) target.id = try arena.dupe(u8, id);
                }
                if (call.type) |kind| {
                    if (kind.len != 0) target.type = try arena.dupe(u8, kind);
                }
                if (call.function.name.len != 0) {
                    target.function.name = try arena.dupe(u8, call.function.name);
                }
                try self.tool_arguments.items[slot].appendSlice(arena, call.function.arguments);
            }
            if (choice.finish_reason) |reason| self.finish_reason = try arena.dupe(u8, reason);
            if (choice.logprobs) |logprobs| {
                if (self.logprobs_content == null) {
                    self.logprobs_content = .empty;
                    self.logprobs_reasoning = .empty;
                }
                try self.logprobs_content.?.appendSlice(arena, logprobs.content);
                try self.logprobs_reasoning.?.appendSlice(arena, logprobs.reasoning_content);
            }
        }

        fn slotFor(self: *Accumulator, arena: Allocator, index: i64) !usize {
            for (self.tool_calls.items, 0..) |call, i| {
                if ((call.index orelse 0) == index) return i;
            }
            try self.tool_calls.append(arena, .{ .index = index });
            try self.tool_arguments.append(arena, .empty);
            return self.tool_calls.items.len - 1;
        }

        fn build(self: *Accumulator, arena: Allocator) !Choice {
            var message: GeneratedMessage = .{
                .role = if (self.role.len == 0) Role.assistant else self.role,
                .content = try arena.dupe(u8, self.content.items),
                .reasoning_content = try arena.dupe(u8, self.reasoning_content.items),
            };
            if (self.tool_calls.items.len != 0) {
                const calls = try arena.alloc(ToolCall, self.tool_calls.items.len);
                for (self.tool_calls.items, self.tool_arguments.items, calls) |call, arguments, *out| {
                    out.* = call;
                    out.function.arguments = try arena.dupe(u8, arguments.items);
                }
                message.tool_calls = calls;
            }
            var logprobs: ?Logprobs = null;
            if (self.logprobs_content) |content| {
                logprobs = .{
                    .content = content.items,
                    .reasoning_content = self.logprobs_reasoning.?.items,
                };
            }
            return .{
                .index = self.index,
                .finish_reason = self.finish_reason,
                .message = message,
                .logprobs = logprobs,
            };
        }
    };
};

/// Fill-In-the-Middle completion: POST /completions, as documented at
/// https://api-docs.deepseek.com/api/create-completion. The caller supplies a
/// prefix and an optional suffix and the model fills in between them.
///
/// The endpoint is a Beta feature, so it always needs the Beta API root:
/// `send` and `sendStream` reject a client built without it.
///
/// The endpoint runs in non-thinking mode only and generates at most 4K
/// tokens, which is why it has no thinking parameters and caps max_tokens at
/// 4096.
pub const fim = struct {
    /// The endpoint's path, relative to the API root.
    pub const path = "/completions";

    /// Object type of a completion and of a streamed chunk.
    pub const Object = struct {
        pub const text_completion = "text_completion";
    };

    /// `finish_reason` values. FIM never calls tools, so there is no
    /// "tool_calls".
    pub const FinishReason = struct {
        pub const stop = "stop";
        pub const length = "length";
        pub const content_filter = "content_filter";
        pub const insufficient_system_resource = "insufficient_system_resource";
        pub const aborted = "aborted";
    };

    /// Documented request limits. The 4K output ceiling is from the FIM guide,
    /// which notes the model generates at most 4K tokens for this endpoint.
    pub const max_output_tokens = 4096;
    pub const max_stop_sequences = 16;
    pub const max_logprobs = 20;

    /// The body of POST /completions. Optional parameters are optional fields
    /// so that "unset" stays distinguishable from a zero value.
    pub const Request = struct {
        /// `Model.flash` or `Model.v4_pro`. Required.
        model: []const u8,

        /// The text before the completion. Required.
        prompt: []const u8,

        /// The text the completion must lead into. Cannot be combined with
        /// `echo`.
        suffix: ?[]const u8 = null,

        /// Repeats the prompt before the completion. Cannot be combined with
        /// `suffix` or `logprobs`.
        echo: ?bool = null,

        /// Asks for the log probabilities of the most likely output tokens,
        /// from 0 to `max_logprobs`. The response carries up to one more entry
        /// than requested, since the sampled token is always reported. Cannot
        /// be combined with `echo`.
        logprobs: ?i64 = null,

        /// Bounds the generated tokens, 1 to `max_output_tokens`.
        max_tokens: ?i64 = null,

        /// Up to `max_stop_sequences` sequences at which generation stops. The
        /// returned text does not contain the stop sequence.
        stop: ?Stop = null,

        /// Samples between 0 and 2.
        temperature: ?f64 = null,

        /// Nucleus sampling, greater than 0 and at most 1.
        top_p: ?f64 = null,

        /// Asks for server-sent events instead of one JSON body. `send`
        /// requires it to be false; `sendStream` sets it.
        stream: ?bool = null,

        /// Configures a streamed response and requires `stream`.
        stream_options: ?StreamOptions = null,

        pub const json = .{
            .fields = .{ .suffix = .{ .skip_if_empty = true } },
        };

        /// Reports whether the request satisfies the constraints the API
        /// documents for POST /completions, so that a request the API would
        /// reject is caught before it is sent. `send` and `sendStream` call
        /// it, so callers rarely need it.
        pub fn validate(self: *const Request) Result(void, Invalid) {
            if (self.check(self.stream orelse false)) |invalid| return .{ .err = invalid };
            return .{ .ok = {} };
        }

        /// The first constraint the request breaks, or null when it breaks
        /// none. `streaming` is whether the call being made streams, since
        /// stream_options is only valid there.
        fn check(self: *const Request, streaming: bool) ?Invalid {
            if (std.mem.trim(u8, self.model, " \t\r\n").len == 0) return .model_required;
            if (self.prompt.len == 0) return .prompt_required;
            if (self.echo orelse false) {
                if (self.suffix) |suffix| {
                    if (suffix.len != 0) return .echo_with_suffix;
                }
                if (self.logprobs != null) return .echo_with_logprobs;
            }
            if (self.logprobs) |logprobs| {
                if (logprobs < 0 or logprobs > max_logprobs) {
                    return .{ .logprobs_out_of_range = logprobs };
                }
            }
            if (self.max_tokens) |max_tokens| {
                if (max_tokens < 1 or max_tokens > max_output_tokens) {
                    return .{ .max_tokens_out_of_range = max_tokens };
                }
            }
            if (self.stop) |stop| {
                if (stop.sequences.len > max_stop_sequences) {
                    return .{ .too_many_stop_sequences = stop.sequences.len };
                }
                for (stop.sequences) |sequence| {
                    if (sequence.len == 0) return .empty_stop_sequence;
                }
            }
            if (self.temperature) |temperature| {
                if (!(temperature >= 0 and temperature <= 2)) {
                    return .{ .temperature_out_of_range = temperature };
                }
            }
            if (self.top_p) |top_p| {
                if (!(top_p > 0 and top_p <= 1)) return .{ .top_p_out_of_range = top_p };
            }
            if (self.stream_options != null and !streaming) return .stream_options_require_stream;
            return null;
        }
    };

    /// A constraint a request breaks, with the field or value that explains
    /// it.
    pub const Invalid = union(enum) {
        model_required,
        prompt_required,
        echo_with_suffix,
        echo_with_logprobs,
        logprobs_out_of_range: i64,
        max_tokens_out_of_range: i64,
        /// How many sequences were given, against a limit of 16.
        too_many_stop_sequences: usize,
        empty_stop_sequence,
        temperature_out_of_range: f64,
        top_p_out_of_range: f64,
        stream_options_require_stream,

        /// Renders the failure the way the API documents the constraint.
        pub fn format(self: Invalid, writer: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .model_required => try writer.writeAll("model is required"),
                .prompt_required => try writer.writeAll("prompt is required"),
                .echo_with_suffix => try writer.writeAll("echo cannot be combined with suffix"),
                .echo_with_logprobs => try writer.writeAll("echo cannot be combined with logprobs"),
                .logprobs_out_of_range => |value| try writer.print("logprobs must be between 0 and {d}, got {d}", .{ max_logprobs, value }),
                .max_tokens_out_of_range => |value| try writer.print("max_tokens must be between 1 and {d}, got {d}", .{ max_output_tokens, value }),
                .too_many_stop_sequences => |count| try writer.print("stop accepts at most {d} sequences, got {d}", .{ max_stop_sequences, count }),
                .empty_stop_sequence => try writer.writeAll("stop sequences must not be empty"),
                .temperature_out_of_range => |value| try writer.print("temperature must be between 0 and 2, got {d}", .{value}),
                .top_p_out_of_range => |value| try writer.print("top_p must be greater than 0 and at most 1, got {d}", .{value}),
                .stream_options_require_stream => try writer.writeAll("stream_options requires stream"),
            }
        }
    };

    /// What a FIM call failed with, when it is part of the API's contract
    /// rather than an allocation or a socket.
    pub const Failure = union(enum) {
        /// The request breaks a documented constraint; see `Invalid.format`.
        invalid: Invalid,
        /// The API answered with an error envelope.
        api: APIError,
        /// The request asked for streaming; call `sendStream` instead.
        stream_requested,
        /// This endpoint only exists under the Beta API root.
        beta_required,

        pub fn format(self: Failure, writer: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .invalid => |invalid| try invalid.format(writer),
                .api => |envelope| try envelope.format(writer),
                .stream_requested => try writer.writeAll("Request.stream is true; use sendStream"),
                .beta_required => try writer.writeAll("FIM completion needs the Beta API root; build the client with beta = true"),
            }
        }
    };

    /// A non-streaming response, and the result of collecting a stream.
    pub const Completion = struct {
        id: []const u8 = "",
        object: []const u8 = "",
        created: i64 = 0,
        model: []const u8 = "",
        system_fingerprint: []const u8 = "",
        choices: []const Choice = &.{},
        usage: ?Usage = null,

        /// The text of the first choice, or "" when the response carries no
        /// choice.
        pub fn text(self: *const Completion) []const u8 {
            if (self.choices.len == 0) return "";
            return self.choices[0].text;
        }
    };

    /// One completion alternative; within a streamed chunk it carries the text
    /// added so far.
    pub const Choice = struct {
        /// Null until the model stops.
        finish_reason: ?[]const u8 = null,
        index: i64 = 0,
        text: []const u8 = "",
        logprobs: ?Logprobs = null,
    };

    /// The legacy completions log-probability report: parallel lists of the
    /// sampled tokens, their positions and their probabilities, plus the most
    /// likely alternatives at each position.
    pub const Logprobs = struct {
        text_offset: []const i64 = &.{},
        token_logprobs: []const f64 = &.{},
        tokens: []const []const u8 = &.{},
        top_logprobs: []const std.json.ArrayHashMap(f64) = &.{},
    };

    /// One event of a streamed response, in the shape of a completion whose
    /// text grows chunk by chunk.
    pub const Chunk = struct {
        id: []const u8 = "",
        object: []const u8 = "",
        created: i64 = 0,
        model: []const u8 = "",
        system_fingerprint: []const u8 = "",
        choices: []const Choice = &.{},
        usage: ?Usage = null,
    };

    /// Sends a non-streaming request. A request that asks for streaming is
    /// refused; use `sendStream`.
    pub fn send(
        client: *Client,
        request: *const Request,
    ) !Result(std.json.Parsed(Completion), Failure) {
        if (request.stream orelse false) return .{ .err = .stream_requested };
        if (!client.beta) return .{ .err = .beta_required };
        if (request.check(false)) |invalid| return .{ .err = .{ .invalid = invalid } };
        const payload = try encode(client.allocator, request);
        defer client.allocator.free(payload);
        const response = switch (try client.post(path, payload, false)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = .{ .api = envelope } },
        };
        defer response.deinit();
        return .{ .ok = try response.parse(Completion) };
    }

    /// Sends a streaming request and returns the event stream. The request is
    /// sent with stream set to true whatever `request.stream` says, and the
    /// caller must deinit the returned stream.
    pub fn sendStream(
        client: *Client,
        request: *const Request,
    ) !Result(Stream, Failure) {
        if (!client.beta) return .{ .err = .beta_required };
        if (request.check(true)) |invalid| return .{ .err = .{ .invalid = invalid } };
        var body = request.*;
        body.stream = true;
        const payload = try encode(client.allocator, &body);
        defer client.allocator.free(payload);
        const response = switch (try client.post(path, payload, true)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = .{ .api = envelope } },
        };
        return .{ .ok = .{ .inner = newEventStream(Chunk, response) } };
    }

    /// Encodes a request body with the client's allocator.
    fn encode(allocator: Allocator, request: *const Request) ![]u8 {
        return json_encoder.stringify(allocator, request.*);
    }

    /// A streamed FIM completion response. `recv` returns the chunks in order,
    /// `usage` the tokens billed for the request, and `collect` assembles the
    /// whole response instead.
    pub const Stream = struct {
        inner: EventStream(Chunk),

        /// Releases the connection.
        pub fn deinit(self: *Stream) void {
            self.inner.deinit();
        }

        /// Returns the next chunk of the response, or null after the final
        /// event. `arena` may be reset once the chunk is no longer needed.
        pub fn recv(self: *Stream, arena: Allocator) EventStream(Chunk).ReadError!?Chunk {
            return self.inner.recv(arena);
        }

        /// The tokens the API reported for the request, or null while they
        /// have not arrived.
        pub fn usage(self: *const Stream) ?Usage {
            return self.inner.usage();
        }

        /// Reads the rest of the stream and assembles the text of each choice,
        /// its log probabilities and the usage into the same completion `send`
        /// returns.
        pub fn collect(self: *Stream, allocator: Allocator) !Collected(Completion) {
            var collected: Collected(Completion) = .{
                .arena = .init(allocator),
                .value = .{ .object = Object.text_completion },
            };
            errdefer collected.arena.deinit();
            const arena = collected.arena.allocator();

            var accumulators: std.ArrayListUnmanaged(Accumulator) = .empty;
            while (try self.recv(arena)) |chunk| {
                if (collected.value.id.len == 0) {
                    collected.value.id = chunk.id;
                    collected.value.created = chunk.created;
                    collected.value.model = chunk.model;
                    collected.value.system_fingerprint = chunk.system_fingerprint;
                }
                for (chunk.choices) |choice| {
                    const slot = try accumulatorFor(arena, &accumulators, choice.index);
                    try accumulators.items[slot].merge(arena, choice);
                }
            }
            collected.value.usage = self.usage();

            std.mem.sort(Accumulator, accumulators.items, {}, byIndex);
            const choices = try arena.alloc(Choice, accumulators.items.len);
            for (accumulators.items, choices) |*accumulator, *choice| {
                choice.* = accumulator.build();
            }
            collected.value.choices = choices;
            return collected;
        }
    };

    fn byIndex(_: void, a: Accumulator, b: Accumulator) bool {
        return a.index < b.index;
    }

    fn accumulatorFor(
        arena: Allocator,
        accumulators: *std.ArrayListUnmanaged(Accumulator),
        index: i64,
    ) !usize {
        for (accumulators.items, 0..) |accumulator, i| {
            if (accumulator.index == index) return i;
        }
        try accumulators.append(arena, .{
            .index = index,
            .text = .empty,
            .text_offset = .empty,
            .token_logprobs = .empty,
            .tokens = .empty,
            .top_logprobs = .empty,
        });
        return accumulators.items.len - 1;
    }

    /// Assembles the deltas of one choice.
    const Accumulator = struct {
        index: i64,
        text: std.ArrayListUnmanaged(u8),
        finish_reason: []const u8 = "",
        text_offset: std.ArrayListUnmanaged(i64),
        token_logprobs: std.ArrayListUnmanaged(f64),
        tokens: std.ArrayListUnmanaged([]const u8),
        top_logprobs: std.ArrayListUnmanaged(std.json.ArrayHashMap(f64)),
        saw_logprobs: bool = false,

        fn merge(self: *Accumulator, arena: Allocator, choice: Choice) !void {
            try self.text.appendSlice(arena, choice.text);
            if (choice.finish_reason) |reason| {
                self.finish_reason = try arena.dupe(u8, reason);
            }
            if (choice.logprobs) |logprobs| {
                self.saw_logprobs = true;
                // Text offsets are absolute, so the lists are appended as they
                // arrive.
                try self.text_offset.appendSlice(arena, logprobs.text_offset);
                try self.token_logprobs.appendSlice(arena, logprobs.token_logprobs);
                try self.tokens.appendSlice(arena, logprobs.tokens);
                try self.top_logprobs.appendSlice(arena, logprobs.top_logprobs);
            }
        }

        fn build(self: *Accumulator) Choice {
            return .{
                .index = self.index,
                .text = self.text.items,
                .finish_reason = self.finish_reason,
                .logprobs = if (self.saw_logprobs) .{
                    .text_offset = self.text_offset.items,
                    .token_logprobs = self.token_logprobs.items,
                    .tokens = self.tokens.items,
                    .top_logprobs = self.top_logprobs.items,
                } else null,
            };
        }
    };
};

test {
    _ = @import("deepseek_test.zig");
}
