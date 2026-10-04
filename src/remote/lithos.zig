//! LithosAI API client.
//!
//! LithosAI (https://api.lithosai.cloud/v1) is an OpenAI-compatible
//! inference engine over open-weight models. This client speaks the subset the
//! vendor documents in its OpenAPI reference (docs.lithosai.com/openapi.yaml,
//! `info.version` 2026-09-17) and nothing beyond it:
//!
//!   * `models` — `GET /models` and `GET /models/{author}/{slug}`
//!   * `chat`   — `POST /chat/completions`, streamed and not
//!
//! Endpoints the vendor does not implement (`/completions`, `/embeddings`,
//! `/responses`, `/batches`) answer 404 and are not reachable here.
//!
//! Deciding points:
//!
//!   * Thinking is controlled by one field, `reasoning_effort`, which takes
//!     either a named effort (`none|minimal|low|medium|high|xhigh|max`) or a
//!     float in `[0, 0.99]`. The two forms are one union, `ReasoningEffort`,
//!     so neither is spelled as a string that has to be parsed. Whether a
//!     given model obeys `none` is a per-model fact, not a wire fact, and is
//!     kept out of this type; see lithos_models.md.
//!   * Failures the API defines are values, not Zig errors: a call returns
//!     `Result(Success, Failure)` so the API's own envelope — which of the two
//!     shapes it uses, and what it says — survives to the caller. Allocation
//!     and socket failures stay Zig errors, where `try` and `defer` still do
//!     their job.
//!   * The API returns two error shapes: its own `{error:{...}}` and the
//!     inference engine's raw `{object:"error",...,code:<int>}` passthrough.
//!     `APIError` carries which one it read, so a caller can tell them apart.
//!   * The client, like `std.http.Client` under it, is safe for concurrent
//!     use; individual `Response` values are not.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;

const json_encoder = @import("../json_encoder.zig");

/// The API root. Paths below are appended to it, so the `/v1` segment belongs
/// to this constant, not to a path.
pub const default_base_url = "https://api.lithosai.cloud/v1";

const max_error_body = 64 << 10;

// ---------------------------------------------------------------------------
// Errors and results
// ---------------------------------------------------------------------------

/// An error response from the API, as much of the envelope as was decodable.
pub const APIError = struct {
    status_code: u16,
    /// Which error shape the body carried.
    form: Form = .envelope,
    /// The message, or the raw body when it was not an envelope.
    message: []u8 = &.{},
    /// The `type` field, e.g. `invalid_request_error` or an engine error class.
    type: []u8 = &.{},
    /// The `param` field, when the envelope named one.
    param: []u8 = &.{},
    /// The `code` field, string or integer, rendered as text.
    code: []u8 = &.{},
    /// `retry-after`, in seconds, when the response advised one.
    retry_after: ?i64 = null,
    /// `retry-after-ms`, the more precise of the two, when present.
    retry_after_ms: ?i64 = null,
    /// `x-should-retry`: false where waiting will not change the answer.
    should_retry: ?bool = null,

    /// The two documented shapes, plus a body that was neither.
    pub const Form = enum {
        /// `{error:{message,type,param,code}}` — the API's own envelope.
        envelope,
        /// `{object:"error",message,type,param,code:<integer>}` — the
        /// inference engine's raw validation error, passed through.
        engine,
        /// A body that did not decode as either, kept verbatim as `message`.
        plain,
    };

    /// `allocator` must be the one the client was built with.
    pub fn deinit(self: *APIError, allocator: Allocator) void {
        allocator.free(self.message);
        allocator.free(self.type);
        allocator.free(self.param);
        allocator.free(self.code);
        self.* = undefined;
    }

    /// Renders the error, e.g.
    /// `lithos: HTTP 429 rate_limit_exceeded/429001: Rate limit reached`.
    pub fn format(self: APIError, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("lithos: HTTP {d}", .{self.status_code});
        if (self.type.len != 0 and self.code.len != 0) {
            try writer.print(" {s}/{s}", .{ self.type, self.code });
        } else if (self.type.len != 0) {
            try writer.print(" {s}", .{self.type});
        } else if (self.code.len != 0) {
            try writer.print(" {s}", .{self.code});
        }
        if (self.param.len != 0) try writer.print(" (param {s})", .{self.param});
        if (self.message.len != 0) try writer.print(": {s}", .{self.message});
        if (self.should_retry) |should| {
            if (!should) try writer.writeAll(" [x-should-retry: false]");
        }
    }
};

/// Pure: no socket, no client, so it is testable against canned bytes.
///
/// Both documented shapes are read, and a body that is neither is kept whole
/// as `message` — a 400 can arrive as plain text
/// (`inference error: BadRequest - ...`), which is not an envelope and must
/// not be dropped.
pub fn parseError(allocator: Allocator, status_code: u16, body: []const u8) Allocator.Error!APIError {
    const text = std.mem.trim(u8, body, " \t\r\n");
    var out: APIError = .{ .status_code = status_code, .form = .plain };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{
        .ignore_unknown_fields = true,
        // Keep numbers as their source text: `code` is a string in one shape
        // and an integer in the other.
        .parse_numbers = false,
    }) catch {
        out.message = try allocator.dupe(u8, text);
        return out;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            out.message = try allocator.dupe(u8, text);
            return out;
        },
    };

    if (root.get("error")) |envelope| {
        switch (envelope) {
            .object => |fields| {
                out.form = .envelope;
                return try readFields(allocator, out, fields);
            },
            else => {},
        }
    }

    if (stringField(root, "object")) |object| {
        if (std.mem.eql(u8, object, "error")) {
            out.form = .engine;
            return try readFields(allocator, out, root);
        }
    }

    out.message = try allocator.dupe(u8, text);
    return out;
}

/// `code` may be a string or a number; both render to text.
fn readFields(
    allocator: Allocator,
    out: APIError,
    object: std.json.ObjectMap,
) Allocator.Error!APIError {
    var result = out;
    errdefer result.deinit(allocator);
    if (stringField(object, "message")) |message| result.message = try allocator.dupe(u8, message);
    if (stringField(object, "type")) |kind| result.type = try allocator.dupe(u8, kind);
    if (stringField(object, "param")) |param| result.param = try allocator.dupe(u8, param);
    if (object.get("code")) |code| {
        result.code = try allocator.dupe(u8, switch (code) {
            .string => |s| s,
            .number_string => |s| s,
            else => "",
        });
    }
    return result;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// What a call produced, or why it did not.
pub fn Result(comptime Success: type, comptime Failure: type) type {
    return union(enum) {
        ok: Success,
        err: Failure,

        pub fn failure(self: @This()) ?Failure {
            return switch (self) {
                .ok => null,
                .err => |why| why,
            };
        }
    };
}

/// A stream result that owns everything in `value`.
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

/// The per-minute budgets the API reports on every 200 response.
pub const RateLimits = struct {
    limit_requests: ?i64 = null,
    remaining_requests: ?i64 = null,
    /// e.g. `1s`; owned by the response.
    reset_requests: ?[]u8 = null,
    limit_tokens: ?i64 = null,
    remaining_tokens: ?i64 = null,
    /// e.g. `0s`; owned by the response.
    reset_tokens: ?[]u8 = null,

    fn deinit(self: *RateLimits, allocator: Allocator) void {
        if (self.reset_requests) |value| allocator.free(value);
        if (self.reset_tokens) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Reports the tokens billed for a request. Every endpoint returns it in this
/// shape.
pub const Usage = struct {
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    total_tokens: i64 = 0,
    /// Left unmodelled: the reference says only `object|null`.
    prompt_tokens_details: ?std.json.Value = null,
    completion_tokens_details: ?CompletionTokensDetails = null,
};

pub const CompletionTokensDetails = struct {
    reasoning_tokens: i64 = 0,
};

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Sends requests to the LithosAI API.
pub const Client = struct {
    allocator: Allocator,
    io: Io,
    /// The key sent as `Bearer`; caller-owned, must outlive the client.
    api_key: []const u8,
    /// The API root without a trailing slash; caller-owned.
    base_url: []const u8,
    http_client: http.Client,

    pub const Options = struct {
        /// Another API root, such as a self-hosted engine. A trailing slash
        /// is optional. The default is `default_base_url`.
        base_url: ?[]const u8 = null,
    };

    pub const InitError = error{
        /// The key was empty or only whitespace.
        ApiKeyRequired,
    };

    /// The key and any configured base URL must outlive the client.
    pub fn init(allocator: Allocator, io: Io, api_key: []const u8, options: Options) InitError!Client {
        if (std.mem.trim(u8, api_key, " \t\r\n").len == 0) return error.ApiKeyRequired;
        const base = options.base_url orelse default_base_url;
        return .{
            .allocator = allocator,
            .io = io,
            .api_key = api_key,
            .base_url = std.mem.trimEnd(u8, base, "/"),
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    /// All responses must be deinited first.
    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
        self.* = undefined;
    }

    /// Sends `path` relative to the API root and returns the response to a 2xx
    /// status. Any other status comes back as the API's error envelope, retry
    /// advice and all. `payload` is a POST body, or null for a bodyless GET;
    /// `accept_sse` asks for a streamed response.
    fn fetch(
        self: *Client,
        method: http.Method,
        path: []const u8,
        payload: ?[]const u8,
        accept_sse: bool,
    ) !Result(*Response, APIError) {
        const gpa = self.allocator;
        const url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ self.base_url, path });
        defer gpa.free(url);
        const uri = try std.Uri.parse(url);

        const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{self.api_key});
        defer gpa.free(bearer);

        var headers: [3]http.Header = undefined;
        var count: usize = 0;
        headers[count] = .{ .name = "authorization", .value = bearer };
        count += 1;
        if (payload != null) {
            headers[count] = .{ .name = "content-type", .value = "application/json" };
            count += 1;
        }
        if (accept_sse) {
            headers[count] = .{ .name = "accept", .value = "text/event-stream" };
            count += 1;
        }

        const request = try gpa.create(http.Client.Request);
        errdefer gpa.destroy(request);
        request.* = try self.http_client.request(method, uri, .{
            .extra_headers = headers[0..count],
            // A redirect means the root is misconfigured; the API never
            // redirects these.
            .redirect_behavior = .not_allowed,
        });
        errdefer request.deinit();

        if (payload) |body_bytes| {
            request.transfer_encoding = .{ .content_length = body_bytes.len };
            var body = try request.sendBody(&.{});
            try body.writer.writeAll(body_bytes);
            try body.end();
            try request.connection.?.flush();
        } else {
            try request.sendBodiless();
        }

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
        errdefer gpa.free(transfer_buffer);
        const rate_limits = try parseRateLimits(gpa, &head);
        errdefer {
            var limits = rate_limits;
            limits.deinit(gpa);
        }
        response.* = .{
            .allocator = gpa,
            .request = request,
            .head = head,
            .transfer_buffer = transfer_buffer,
            .rate_limits = rate_limits,
        };
        return .{ .ok = response };
    }

    fn readApiError(self: *Client, head: *http.Client.Response) !APIError {
        // The retry headers are read first: initializing the body reader below
        // invalidates the header bytes they point into.
        const retry_after = headerInt(head, "retry-after");
        const retry_after_ms = headerInt(head, "retry-after-ms");
        const should_retry = headerBool(head, "x-should-retry");

        var buffer: [max_error_body]u8 = undefined;
        var transfer: [512]u8 = undefined;
        const length = readUpTo(head.reader(&transfer), &buffer);
        var envelope = try parseError(self.allocator, @backingInt(head.head.status), buffer[0..length]);
        envelope.retry_after = retry_after;
        envelope.retry_after_ms = retry_after_ms;
        envelope.should_retry = should_retry;
        return envelope;
    }
};

/// A body that breaks partway is not an error here: what arrived is what the
/// caller has. The count comes from the writes, not from the buffer's length,
/// because an allocation is not zeroed and the tail would be uninitialized.
///
/// A read that returns zero has moved the reader along without handing bytes
/// over yet — what a reader that fills its own buffer first does, and what
/// every TLS connection's reader does — so it is a round to come back for
/// rather than the end of the body.
fn readUpTo(reader: *Io.Reader, buffer: []u8) usize {
    var writer = Io.Writer.fixed(buffer);
    var length: usize = 0;
    while (length < buffer.len) {
        const n = reader.stream(&writer, .limited(buffer.len - length)) catch break;
        length += n;
    }
    return length;
}

/// Names compare case-insensitively.
fn headerValue(head: *const http.Client.Response, name: []const u8) ?[]const u8 {
    var iterator = head.head.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn headerInt(head: *const http.Client.Response, name: []const u8) ?i64 {
    const value = headerValue(head, name) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, value, " \t"), 10) catch null;
}

fn headerBool(head: *const http.Client.Response, name: []const u8) ?bool {
    const value = headerValue(head, name) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    return null;
}

/// Best-effort: a header that is absent or unparsable stays null.
fn parseRateLimits(allocator: Allocator, head: *const http.Client.Response) !RateLimits {
    var limits: RateLimits = .{
        .limit_requests = headerInt(head, "x-ratelimit-limit-requests"),
        .remaining_requests = headerInt(head, "x-ratelimit-remaining-requests"),
        .limit_tokens = headerInt(head, "x-ratelimit-limit-tokens"),
        .remaining_tokens = headerInt(head, "x-ratelimit-remaining-tokens"),
    };
    errdefer limits.deinit(allocator);
    if (headerValue(head, "x-ratelimit-reset-requests")) |value| {
        limits.reset_requests = try allocator.dupe(u8, value);
    }
    if (headerValue(head, "x-ratelimit-reset-tokens")) |value| {
        limits.reset_tokens = try allocator.dupe(u8, value);
    }
    return limits;
}

/// A response to a 2xx request whose body has not been read yet.
pub const Response = struct {
    allocator: Allocator,
    request: *http.Client.Request,
    head: http.Client.Response,
    transfer_buffer: []u8,
    rate_limits: RateLimits,

    /// Anything read out of the body before this call stays valid; the body
    /// itself does not.
    pub fn deinit(self: *Response) void {
        const allocator = self.allocator;
        self.rate_limits.deinit(allocator);
        self.request.deinit();
        allocator.destroy(self.request);
        allocator.free(self.transfer_buffer);
        allocator.destroy(self);
    }

    pub fn status(self: *const Response) u16 {
        return @backingInt(self.head.head.status);
    }

    pub fn rateLimits(self: *const Response) RateLimits {
        return self.rate_limits;
    }

    /// May be called once.
    pub fn reader(self: *Response) *Io.Reader {
        return self.head.reader(self.transfer_buffer);
    }

    pub fn bodyErr(self: *Response) ?http.Reader.BodyError {
        return self.head.bodyErr();
    }

    /// The returned value owns its strings and must be deinited.
    pub fn parse(self: *Response, comptime T: type) !std.json.Parsed(T) {
        var source = std.json.Reader.init(self.allocator, self.reader());
        defer source.deinit();
        return std.json.parseFromTokenSource(T, self.allocator, &source, .{
            .ignore_unknown_fields = true,
        });
    }
};

// ---------------------------------------------------------------------------
// Server-sent events
// ---------------------------------------------------------------------------

/// Decodes the subset of the Server-Sent Events format the API emits: events
/// of `data:` lines ended by an empty line, with comment lines such as
/// `: keep-alive` and every other field ignored.
const SseReader = struct {
    allocator: Allocator,
    reader: *Io.Reader,
    /// The data of the event being decoded; valid until the next call.
    data: std.ArrayList(u8) = .empty,

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
/// chunks in order and null after the API's `[DONE]` sentinel; `usage` reports
/// the tokens billed for the request, which arrive on the last JSON chunk.
pub fn EventStream(comptime Chunk: type) type {
    comptime {
        if (!@hasField(Chunk, "usage")) @compileError("chunk type " ++ @typeName(Chunk) ++ " needs a usage field");
    }

    return struct {
        const Self = @This();

        /// Every error `recv` can end a stream with. Once one is returned the
        /// stream is closed and later calls return it again.
        pub const ReadError = error{
            /// The response was interrupted, or the body ended without
            /// `[DONE]`.
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

        /// Anything already received stays valid only in the allocator it was
        /// parsed into.
        pub fn deinit(self: *Self) void {
            if (self.response) |response| response.deinit();
            self.sse.data.deinit(self.allocator);
            self.response = null;
        }

        /// Returns the next chunk, parsed into `arena`, or null after the
        /// final event. `arena` may be reset once the chunk is no longer
        /// needed.
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

        pub fn usage(self: *const Self) ?Usage {
            return self.usage_value;
        }

        fn fail(self: *Self, err: ReadError) ReadError {
            if (self.response) |response| response.deinit();
            self.response = null;
            self.failure = err;
            return err;
        }
    };
}

pub fn newEventStream(comptime Chunk: type, response: *Response) EventStream(Chunk) {
    return .{
        .allocator = response.allocator,
        .response = response,
        .sse = .{ .allocator = response.allocator, .reader = response.reader() },
    };
}

// ---------------------------------------------------------------------------
// Models: GET /models and GET /models/{author}/{slug}
// ---------------------------------------------------------------------------

/// Model discovery: https://docs.lithosai.com — the Models tag.
pub const models = struct {
    /// The list endpoint, relative to the API root.
    pub const path = "/models";

    /// One model offering, as the endpoint lists it. The rows carry no limits,
    /// tariffs or capability metadata, so none is modelled.
    pub const Model = struct {
        id: []const u8 = "",
        object: []const u8 = "",
        /// Unix seconds.
        created: i64 = 0,
        owned_by: []const u8 = "",
    };

    /// The body of `GET /models`.
    pub const List = struct {
        object: []const u8 = "",
        data: []const Model = &.{},
    };

    /// Credential-scoped: the endpoint answers 401 without a valid key.
    pub fn list(client: *Client) !Result(std.json.Parsed(List), APIError) {
        const response = switch (try client.fetch(.GET, path, null, false)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = envelope },
        };
        defer response.deinit();
        return .{ .ok = try response.parse(List) };
    }

    /// The id is sent as the two path segments it already is, e.g.
    /// `moonshotai/Kimi-K3`.
    pub fn retrieve(client: *Client, id: []const u8) !Result(std.json.Parsed(Model), APIError) {
        const arena = client.allocator;
        const endpoint = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, id });
        defer arena.free(endpoint);
        const response = switch (try client.fetch(.GET, endpoint, null, false)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = envelope },
        };
        defer response.deinit();
        return .{ .ok = try response.parse(Model) };
    }
};

// ---------------------------------------------------------------------------
// Chat Completions: POST /chat/completions
// ---------------------------------------------------------------------------

/// Chat Completions: POST /chat/completions, as documented in the vendor's
/// OpenAPI reference under the Chat tag.
///
/// It covers the whole request surface — messages with text and image parts,
/// tools, JSON output, logprobs, stop sequences, sampling, the thinking
/// control — the non-streaming and streaming response shapes, and both error
/// shapes.
///
/// Per-model constraints (which model insists on `n = 1`, which reads images,
/// which ignores `none`) are deliberately not encoded here; see
/// lithos_models.md.
pub const chat = struct {
    /// The endpoint's path, relative to the API root.
    pub const path = "/chat/completions";

    /// Roles of a request or response message.
    pub const Role = struct {
        pub const system = "system";
        pub const user = "user";
        pub const assistant = "assistant";
        pub const tool = "tool";
        pub const function = "function";
        pub const developer = "developer";
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
        pub const tool_calls = "tool_calls";
        pub const content_filter = "content_filter";
    };

    /// The only tool type the API defines.
    pub const ToolType = struct {
        pub const function = "function";
    };

    /// Which named efforts `reasoning_effort` accepts. `none` is the off
    /// switch; the rest are DeepSeek's published ladder. A model may decline
    /// to honour `none`, which is a per-model fact, not a wire fact.
    pub const NamedEffort = enum { none, minimal, low, medium, high, xhigh, max };

    /// The value of `reasoning_effort`: a named effort, or a budget as a
    /// fraction in `[0, 0.99]`. The budget is not the model's own 1–100 scale;
    /// the endpoint rejects integers on that scale.
    pub const ReasoningEffort = union(enum) {
        named: NamedEffort,
        budget: f64,

        pub const json = .{ .encode = encodeReasoningEffort };
    };

    fn encodeReasoningEffort(e: *json_encoder.Encoder, value: ReasoningEffort) json_encoder.Error!void {
        switch (value) {
            .named => |named| try e.string(@tagName(named)),
            .budget => |budget| try e.float(budget),
        }
    }

    /// Documented request bounds from the OpenAPI reference.
    pub const max_temperature = 2;
    pub const max_top_p = 1;
    pub const max_penalty = 2;
    pub const max_reasoning_budget = 0.99;
    pub const max_top_logprobs = 20;

    /// A block of a message body: text, or an image referenced by URL or data
    /// URL.
    pub const Part = union(enum) {
        text: []const u8,
        image_url: ImageUrl,

        pub const json = .{ .tag_key = "type" };
    };

    /// An image referenced by http(s) URL or base64 data URL.
    pub const ImageUrl = struct {
        url: []const u8,
        detail: ?[]const u8 = null,
    };

    /// The body of a message: plain text, or a list of content parts. It
    /// encodes as a JSON string when it is text and as an array otherwise.
    pub const Content = union(enum) {
        text: []const u8,
        parts: []const Part,

        pub const json = .{ .encode = encodeContent };
    };

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

    pub fn text(content: []const u8) Content {
        return .{ .text = content };
    }

    /// One entry of a conversation. A closed set of six variants, one per role
    /// the API defines, so a field a role does not take cannot be built.
    pub const Message = union(enum) {
        system: SystemMessage,
        developer: DeveloperMessage,
        user: UserMessage,
        assistant: AssistantMessage,
        tool: ToolMessage,
        function: FunctionMessage,

        pub const json = .{
            .tag_key = "role",
            .fields = .{
                .system = .{ .flatten = true },
                .developer = .{ .flatten = true },
                .user = .{ .flatten = true },
                .assistant = .{ .flatten = true },
                .tool = .{ .flatten = true },
                .function = .{ .flatten = true },
            },
        };

        pub fn role(self: Message) []const u8 {
            return switch (self) {
                .system => Role.system,
                .developer => Role.developer,
                .user => Role.user,
                .assistant => Role.assistant,
                .tool => Role.tool,
                .function => Role.function,
            };
        }
    };

    /// The instruction that steers the model.
    pub const SystemMessage = struct {
        content: Content,
        name: ?[]const u8 = null,
    };

    /// The instruction in the role the newer OpenAI models take; the endpoint
    /// enumerates `developer` alongside `system`.
    pub const DeveloperMessage = struct {
        content: Content,
        name: ?[]const u8 = null,
    };

    /// Input from the caller: text and images.
    pub const UserMessage = struct {
        content: Content,
        name: ?[]const u8 = null,
    };

    /// A previous model turn replayed into the conversation.
    pub const AssistantMessage = struct {
        /// The answer text; the empty text when the turn only calls tools.
        content: Content = .{ .text = "" },
        name: ?[]const u8 = null,
        tool_calls: ?[]const ToolCall = null,
        /// The chain of thought behind the turn, when the model emitted one.
        reasoning_content: ?[]const u8 = null,

        pub const json = .{
            .fields = .{
                .tool_calls = .{ .skip_if_empty = true },
            },
        };
    };

    /// The result of a tool call, answering one assistant tool call by id.
    pub const ToolMessage = struct {
        content: Content,
        tool_call_id: []const u8,
    };

    /// A legacy function-role message: a function's output, named.
    pub const FunctionMessage = struct {
        content: []const u8,
        name: []const u8,
    };

    pub fn toolResult(tool_call_id: []const u8, content: []const u8) ToolMessage {
        return .{ .tool_call_id = tool_call_id, .content = text(content) };
    }

    /// A function the model may call.
    pub const Tool = struct {
        type: []const u8 = ToolType.function,
        function: Function = .{ .name = "" },
    };

    /// The declaration of a callable function.
    pub const Function = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        /// The arguments schema as JSON Schema text. The endpoint passes it
        /// through; it is written pre-encoded because the vendor's reference
        /// constrains it no further.
        parameters: ?json_encoder.Raw = null,
        strict: ?bool = null,

        pub const json = .{ .fields = .{ .strict = .{ .skip_if_false = true } } };
    };

    /// One call the model requested, or one fragment of it while streaming.
    pub const ToolCall = struct {
        /// Only present in a streamed delta, where it identifies the call the
        /// fragment belongs to.
        index: ?i64 = null,
        id: ?[]const u8 = null,
        type: ?[]const u8 = null,
        function: FunctionCall = .{},
    };

    /// The function a tool call names, and its arguments as a JSON string.
    pub const FunctionCall = struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
    };

    /// How the model may choose tools.
    pub const ToolChoice = union(enum) {
        none,
        auto,
        required,
        /// Force the named function.
        function: []const u8,

        pub const json = .{ .encode = encodeToolChoice };
    };

    fn encodeToolChoice(e: *json_encoder.Encoder, value: ToolChoice) json_encoder.Error!void {
        switch (value) {
            .none => try e.string("none"),
            .auto => try e.string("auto"),
            .required => try e.string("required"),
            .function => |name| {
                try e.beginObject();
                try e.key("type");
                try e.string(ToolType.function);
                try e.key("function");
                try e.beginObject();
                try e.key("name");
                try e.string(name);
                try e.endObject();
                try e.endObject();
            },
        }
    }

    /// Asks for plain text or for a JSON object.
    pub const ResponseFormat = union(enum) {
        text,
        json_object,

        pub const json = .{ .tag_key = "type" };
    };

    /// The sequences at which generation stops. Encodes as a single string
    /// when it holds one sequence and as an array otherwise.
    pub const Stop = struct {
        sequences: []const []const u8,

        pub const json = .{ .encode = encodeStop };
    };

    fn encodeStop(e: *json_encoder.Encoder, stop: Stop) json_encoder.Error!void {
        if (stop.sequences.len == 1) return e.string(stop.sequences[0]);
        try e.beginArray();
        for (stop.sequences) |sequence| try e.string(sequence);
        return e.endArray();
    }

    /// Configures a streamed response.
    pub const StreamOptions = struct {
        /// Puts a `usage` object on the chunks; the last JSON chunk carries
        /// the totals either way.
        include_usage: bool = false,

        pub const json = .{ .fields = .{ .include_usage = .{ .skip_if_false = true } } };
    };

    /// One token-bias entry; `logit_bias` encodes as an object of these.
    pub const LogitBias = struct {
        entries: []const Entry,

        pub const Entry = struct {
            /// The token id, as text.
            token: []const u8,
            /// The bias added to that token's logit, `-100` to `100`.
            bias: f64,
        };

        pub const json = .{ .encode = encodeLogitBias };
    };

    fn encodeLogitBias(e: *json_encoder.Encoder, value: LogitBias) json_encoder.Error!void {
        try e.beginObject();
        for (value.entries) |entry| {
            try e.key(entry.token);
            try e.float(entry.bias);
        }
        return e.endObject();
    }

    /// The body of POST /chat/completions.
    pub const Request = struct {
        /// The model id, e.g. `moonshotai/Kimi-K3`. Required.
        model: []const u8,

        /// The conversation so far. Required; the API accepts one or more.
        messages: []const Message,

        /// The thinking control. Omitted, the model's own default applies —
        /// which the endpoint's ladder documents as `high`.
        reasoning_effort: ?ReasoningEffort = null,

        /// Bounds the generated tokens, reasoning included. Both spellings are
        /// accepted; `max_tokens` is the one the engine reads.
        max_tokens: ?i64 = null,
        max_completion_tokens: ?i64 = null,

        temperature: ?f64 = null,
        top_p: ?f64 = null,
        /// Non-standard; the endpoint accepts it.
        top_k: ?i64 = null,
        /// How many completions to generate.
        n: ?i64 = null,
        stop: ?Stop = null,

        /// Asks for server-sent events instead of one JSON body. `send`
        /// requires it to be false; `sendStream` sets it.
        stream: ?bool = null,
        stream_options: ?StreamOptions = null,

        presence_penalty: ?f64 = null,
        frequency_penalty: ?f64 = null,
        seed: ?i64 = null,
        logprobs: ?bool = null,
        top_logprobs: ?i64 = null,
        logit_bias: ?LogitBias = null,
        response_format: ?ResponseFormat = null,

        tools: ?[]const Tool = null,
        tool_choice: ?ToolChoice = null,

        /// Identifies the end user for abuse review.
        user: ?[]const u8 = null,

        pub const json = .{
            .fields = .{
                .tools = .{ .skip_if_empty = true },
            },
        };

        /// Reports whether the request satisfies the bounds the OpenAPI
        /// reference documents, so a request the API would reject as malformed
        /// is caught before it is sent. `send` and `sendStream` call it. It
        /// checks wire bounds only; per-model rules are not its business.
        pub fn validate(self: *const Request) Result(void, Invalid) {
            if (self.check(self.stream orelse false)) |invalid| return .{ .err = invalid };
            return .{ .ok = {} };
        }

        fn check(self: *const Request, streaming: bool) ?Invalid {
            if (std.mem.trim(u8, self.model, " \t\r\n").len == 0) return .model_required;
            if (self.messages.len == 0) return .messages_required;

            if (self.reasoning_effort) |effort| switch (effort) {
                .named => {},
                .budget => |budget| {
                    if (!(budget >= 0 and budget <= max_reasoning_budget)) {
                        return .{ .reasoning_budget_out_of_range = budget };
                    }
                },
            };

            if (self.max_tokens) |value| if (value < 1) return .{ .max_tokens_out_of_range = value };
            if (self.max_completion_tokens) |value| if (value < 1) return .{ .max_tokens_out_of_range = value };
            if (self.temperature) |value| {
                if (!(value >= 0 and value <= max_temperature)) return .{ .temperature_out_of_range = value };
            }
            if (self.top_p) |value| {
                if (!(value >= 0 and value <= max_top_p)) return .{ .top_p_out_of_range = value };
            }
            if (self.presence_penalty) |value| {
                if (!(value >= -max_penalty and value <= max_penalty)) return .{ .presence_penalty_out_of_range = value };
            }
            if (self.frequency_penalty) |value| {
                if (!(value >= -max_penalty and value <= max_penalty)) return .{ .frequency_penalty_out_of_range = value };
            }
            if (self.n) |value| if (value < 1) return .{ .n_out_of_range = value };
            if (self.top_logprobs) |value| {
                if (value < 0 or value > max_top_logprobs) return .{ .top_logprobs_out_of_range = value };
                if (self.logprobs == null or !self.logprobs.?) return .logprobs_required;
            }
            if (self.stop) |stop| {
                for (stop.sequences) |sequence| {
                    if (sequence.len == 0) return .empty_stop_sequence;
                }
            }
            if (self.stream_options != null and !streaming) return .stream_options_require_stream;
            return null;
        }
    };

    /// A wire bound a request breaks, with the value that explains it.
    pub const Invalid = union(enum) {
        model_required,
        messages_required,
        reasoning_budget_out_of_range: f64,
        max_tokens_out_of_range: i64,
        temperature_out_of_range: f64,
        top_p_out_of_range: f64,
        presence_penalty_out_of_range: f64,
        frequency_penalty_out_of_range: f64,
        n_out_of_range: i64,
        top_logprobs_out_of_range: i64,
        logprobs_required,
        empty_stop_sequence,
        stream_options_require_stream,

        pub fn format(self: Invalid, writer: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .model_required => try writer.writeAll("model is required"),
                .messages_required => try writer.writeAll("at least one message is required"),
                .reasoning_budget_out_of_range => |value| try writer.print("reasoning_effort budget must be in [0, {d}], got {d}", .{ max_reasoning_budget, value }),
                .max_tokens_out_of_range => |value| try writer.print("max_tokens must be at least 1, got {d}", .{value}),
                .temperature_out_of_range => |value| try writer.print("temperature must be in [0, {d}], got {d}", .{ max_temperature, value }),
                .top_p_out_of_range => |value| try writer.print("top_p must be in [0, {d}], got {d}", .{ max_top_p, value }),
                .presence_penalty_out_of_range => |value| try writer.print("presence_penalty must be in [{d}, {d}], got {d}", .{ -max_penalty, max_penalty, value }),
                .frequency_penalty_out_of_range => |value| try writer.print("frequency_penalty must be in [{d}, {d}], got {d}", .{ -max_penalty, max_penalty, value }),
                .n_out_of_range => |value| try writer.print("n must be at least 1, got {d}", .{value}),
                .top_logprobs_out_of_range => |value| try writer.print("top_logprobs must be in [0, {d}], got {d}", .{ max_top_logprobs, value }),
                .logprobs_required => try writer.writeAll("logprobs must be true when top_logprobs is set"),
                .empty_stop_sequence => try writer.writeAll("stop sequences must not be empty"),
                .stream_options_require_stream => try writer.writeAll("stream_options requires stream"),
            }
        }
    };

    /// What a chat call failed with, when it is part of the API's contract
    /// rather than an allocation or a socket.
    pub const Failure = union(enum) {
        /// The request breaks a documented bound; see `Invalid.format`.
        invalid: Invalid,
        /// The API answered with an error envelope.
        api: APIError,
        /// The request asked for streaming; call `sendStream` instead.
        stream_requested,

        pub fn format(self: Failure, writer: *Io.Writer) Io.Writer.Error!void {
            switch (self) {
                .invalid => |invalid| try invalid.format(writer),
                .api => |envelope| try envelope.format(writer),
                .stream_requested => try writer.writeAll("Request.stream is true; use sendStream"),
            }
        }
    };

    // -- Responses ----------------------------------------------------------

    /// A message generated by the model. The two text fields are null wherever
    /// the API has nothing to put there — the answer text of a turn that only
    /// thinks, the chain of thought of a turn that is past thinking — and
    /// empty when it has an empty string.
    pub const GeneratedMessage = struct {
        role: []const u8 = "",
        content: ?[]const u8 = null,
        /// The reasoning trace, on models that emit one. Separate from
        /// `content`.
        reasoning_content: ?[]const u8 = null,
        tool_calls: ?[]const ToolCall = null,

        /// The turn borrows this message's memory, so it is readable only while
        /// the response it was read out of is alive.
        pub fn toAssistant(self: GeneratedMessage) AssistantMessage {
            return .{
                .content = text(self.content orelse ""),
                .reasoning_content = self.reasoning_content,
                .tool_calls = self.tool_calls,
            };
        }
    };

    /// One completed alternative.
    pub const Choice = struct {
        index: i64 = 0,
        message: GeneratedMessage = .{},
        finish_reason: ?[]const u8 = null,
        logprobs: ?std.json.Value = null,
    };

    /// A non-streaming response, and the result of collecting a stream.
    pub const Completion = struct {
        id: []const u8 = "",
        object: []const u8 = "",
        created: i64 = 0,
        model: []const u8 = "",
        choices: []const Choice = &.{},
        usage: ?Usage = null,

        /// A response carrying no choices reads as a zero message rather than a
        /// panic.
        pub fn message(self: *const Completion) GeneratedMessage {
            if (self.choices.len == 0) return .{};
            return self.choices[0].message;
        }
    };

    /// One event of a streamed response.
    pub const Chunk = struct {
        id: []const u8 = "",
        object: []const u8 = "",
        created: i64 = 0,
        model: []const u8 = "",
        choices: []const ChunkChoice = &.{},
        usage: ?Usage = null,
    };

    /// The increment of one choice within a chunk.
    pub const ChunkChoice = struct {
        index: i64 = 0,
        delta: Delta = .{},
        finish_reason: ?[]const u8 = null,
        logprobs: ?std.json.Value = null,
    };

    /// The content a chunk adds.
    pub const Delta = struct {
        role: ?[]const u8 = null,
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        tool_calls: ?[]const ToolCall = null,
    };

    /// A request that asks for streaming is refused; use `sendStream`.
    pub fn send(client: *Client, request: *const Request) !Result(std.json.Parsed(Completion), Failure) {
        if (request.stream orelse false) return .{ .err = .stream_requested };
        if (request.check(false)) |invalid| return .{ .err = .{ .invalid = invalid } };
        const payload = try json_encoder.stringify(client.allocator, request.*);
        defer client.allocator.free(payload);
        const response = switch (try client.fetch(.POST, path, payload, false)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = .{ .api = envelope } },
        };
        defer response.deinit();
        return .{ .ok = try response.parse(Completion) };
    }

    /// The request is sent with `stream` true whatever `request.stream` says,
    /// and the caller must deinit the returned stream.
    pub fn sendStream(client: *Client, request: *const Request) !Result(Stream, Failure) {
        if (request.check(true)) |invalid| return .{ .err = .{ .invalid = invalid } };
        var body = request.*;
        body.stream = true;
        const payload = try json_encoder.stringify(client.allocator, &body);
        defer client.allocator.free(payload);
        const response = switch (try client.fetch(.POST, path, payload, true)) {
            .ok => |response| response,
            .err => |envelope| return .{ .err = .{ .api = envelope } },
        };
        return .{ .ok = .{ .inner = newEventStream(Chunk, response) } };
    }

    /// A streamed Chat Completions response.
    pub const Stream = struct {
        inner: EventStream(Chunk),

        pub fn deinit(self: *Stream) void {
            self.inner.deinit();
        }

        /// Returns the next chunk, or null after the final event. `arena` may
        /// be reset once the chunk is no longer needed.
        pub fn recv(self: *Stream, arena: Allocator) EventStream(Chunk).ReadError!?Chunk {
            return self.inner.recv(arena);
        }

        pub fn usage(self: *const Stream) ?Usage {
            return self.inner.usage();
        }

        /// Reads the rest of the stream and assembles the deltas into the
        /// same completion `send` returns: content, chain of thought, tool
        /// calls whose arguments arrive in fragments, and usage.
        pub fn collect(self: *Stream, allocator: Allocator) !Collected(Completion) {
            var collected: Collected(Completion) = .{
                .arena = .init(allocator),
                .value = .{ .object = Object.completion },
            };
            errdefer collected.arena.deinit();
            const arena = collected.arena.allocator();

            var accumulator: Accumulator = .{};
            while (try self.recv(arena)) |chunk| {
                if (collected.value.id.len == 0) {
                    collected.value.id = chunk.id;
                    collected.value.created = chunk.created;
                    collected.value.model = chunk.model;
                }
                for (chunk.choices) |choice| try accumulator.merge(arena, choice);
            }
            collected.value.usage = self.usage();

            const choices = try arena.alloc(Choice, 1);
            choices[0] = accumulator.build();
            collected.value.choices = choices;
            return collected;
        }
    };

    /// Assembles the deltas of one choice.
    const Accumulator = struct {
        role: []const u8 = "",
        content: std.ArrayListUnmanaged(u8) = .empty,
        reasoning_content: std.ArrayListUnmanaged(u8) = .empty,
        finish_reason: ?[]const u8 = null,
        /// Tool calls in the order first seen, with their arguments collected
        /// separately because they arrive in fragments.
        tool_calls: std.ArrayListUnmanaged(ToolCall) = .empty,
        tool_arguments: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty,

        fn merge(self: *Accumulator, arena: Allocator, choice: ChunkChoice) !void {
            const delta = choice.delta;
            if (delta.role) |role| self.role = role;
            if (delta.content) |chunk| try self.content.appendSlice(arena, chunk);
            if (delta.reasoning_content) |chunk| try self.reasoning_content.appendSlice(arena, chunk);
            for (delta.tool_calls orelse &.{}) |call| {
                const slot = try self.slotFor(arena, call.index orelse 0);
                const target = &self.tool_calls.items[slot];
                if (call.id) |id| {
                    if (id.len != 0) target.id = id;
                }
                if (call.type) |kind| {
                    if (kind.len != 0) target.type = kind;
                }
                if (call.function.name.len != 0) target.function.name = call.function.name;
                try self.tool_arguments.items[slot].appendSlice(arena, call.function.arguments);
            }
            if (choice.finish_reason) |reason| self.finish_reason = reason;
        }

        fn slotFor(self: *Accumulator, arena: Allocator, index: i64) !usize {
            for (self.tool_calls.items, 0..) |call, i| {
                if ((call.index orelse 0) == index) return i;
            }
            try self.tool_calls.append(arena, .{ .index = index });
            try self.tool_arguments.append(arena, .empty);
            return self.tool_calls.items.len - 1;
        }

        fn build(self: *Accumulator) Choice {
            for (self.tool_calls.items, 0..) |*call, i| {
                call.function.arguments = self.tool_arguments.items[i].items;
            }
            return .{
                .index = 0,
                .message = .{
                    .role = if (self.role.len != 0) self.role else Role.assistant,
                    .content = self.content.items,
                    .reasoning_content = if (self.reasoning_content.items.len != 0) self.reasoning_content.items else null,
                    .tool_calls = if (self.tool_calls.items.len != 0) self.tool_calls.items else null,
                },
                .finish_reason = self.finish_reason,
            };
        }
    };
};

test {
    _ = @import("lithos_test.zig");
}