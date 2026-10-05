//! libcurl transport.
//!
//! `std.http.Client` speaks HTTP/1.1 only, and the endpoint serves HTTP/2,
//! which pays once requests overlap (research/http-client.dj). libcurl's easy
//! interface is blocking, so each request runs on its own thread while the
//! body is handed to the caller through a blocking `Io.Reader`; that keeps the
//! pull-based shape `Response.reader()` already had.
//!
//! A request has no error set. `request` returns an `Outcome`: either the
//! response to read, or a `Failure` state saying how the attempt ended, so the
//! caller decides what each state means — a broken endpoint is a property of
//! the endpoint and is not retried, while a transfer failure is not.
//!
//! `Options.require_h2` makes HTTP/2 a requirement rather than a preference.
//! libcurl on its own falls back to HTTP/1.1 in silence (measured in
//! research/http-client.dj); with the option set, a connection that negotiates
//! anything else ends the request as `endpoint_broken` and marks the client, so
//! no later request is even sent.
//!
//! Every request reports its timings — when the response head arrived, when
//! the first body byte arrived, the longest gap between body bytes — and every
//! failure reports libcurl's code and detail. Those numbers are what the
//! connect and idle bounds in `Options` are to be chosen from; neither is set
//! by default yet, so a stalled transfer is still unbounded.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("curl");
const debug = @import("debug.zig");

pub const Method = enum { GET, POST };

/// How much of the response the caller needs before `request` returns. It
/// decides whether a failed transfer can be replayed: a stream that has
/// already handed bytes out cannot, so only `complete` retries.
pub const Mode = enum { stream, complete };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// How a request that produced no response ended. Each is a state the caller
/// acts on, not an error to propagate.
pub const Failure = enum {
    /// Nothing was sent: libcurl was not started, a handle or thread could not
    /// be had, an option was rejected, or a POST had no body. The client is
    /// marked broken, so no later request is sent either.
    setup_failed,
    /// `require_h2` is set and the endpoint does not serve HTTP/2. Nothing was
    /// sent, and nothing will be: the client is marked broken.
    endpoint_broken,
    /// The transfer failed before any response header arrived — name
    /// resolution, TCP, TLS, or the connect bound.
    connect_failed,
    /// The transfer failed after the response started.
    transfer_failed,
    /// `Response.deinit` stopped the transfer before it finished.
    cancelled,
    /// An allocation failed, here or inside libcurl.
    out_of_memory,
};

/// What one request attempt amounts to.
pub const Outcome = union(enum) {
    /// The response head arrived; the body streams through `Response.reader`.
    streaming: *Response,
    /// No response. The state says how the attempt ended.
    failure: Failure,
};

pub const Options = struct {
    /// Require HTTP/2 instead of preferring it. A connection that negotiates
    /// anything else marks the endpoint broken; see `Failure.endpoint_broken`.
    require_h2: bool = false,
    /// How many tries a transfer that failed after the response started gets in
    /// all, the first one included, so 3 means at most two retries. Only
    /// `Mode.complete` retries, because a stream that has handed bytes out
    /// cannot be replayed, and the first try always happens. A connection
    /// failure is never retried whatever this is; it is reported instead.
    transfer_attempts: u8 = 3,
    /// Bound on connection establishment, in milliseconds. Null leaves it
    /// unbounded; set it from the `connect` readings.
    connect_timeout_ms: ?u64 = null,
    /// Abort a transfer whose body stops arriving for this long. Null leaves
    /// it unbounded; set it from the `stall` readings, which is the longest
    /// gap actually seen.
    idle_timeout_ms: ?u64 = null,
    /// Where each request's measurements go, and each failure's cause. Null
    /// logs nothing.
    log: ?debug.Logger = null,
};

pub const Client = struct {
    allocator: Allocator,
    io: Io,
    options: Options,
    /// The state that ended this client. Once set, every request returns it
    /// without being sent: `setup_failed` means libcurl cannot be used at all,
    /// `endpoint_broken` that the endpoint does not serve HTTP/2. Rebuild the
    /// client to try again.
    broken: ?Failure = null,

    /// Never fails: a libcurl that cannot start marks the client broken, and
    /// every request then reports `Failure.setup_failed`.
    pub fn init(allocator: Allocator, io: Io, options: Options) Client {
        var client: Client = .{ .allocator = allocator, .io = io, .options = options };
        if (!initGlobal(io)) client.broken = .setup_failed;
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.* = undefined;
    }

    /// Sends `method` to `url` with `headers` and an optional body.
    ///
    /// A transfer that failed after the response started gets up to
    /// `Options.transfer_attempts` tries in all, but only in `Mode.complete`:
    /// there nothing has reached the caller, so the attempt can be replayed.
    /// A connection failure is never retried — it is mostly the network, so it
    /// is reported and the caller decides whether to try again.
    pub fn request(
        self: *Client,
        method: Method,
        url: []const u8,
        headers: []const Header,
        payload: ?[]const u8,
        mode: Mode,
    ) Outcome {
        if (self.broken) |failure| return .{ .failure = failure };

        var attempts: u8 = 0;
        while (true) {
            attempts += 1;
            switch (self.attempt(method, url, headers, payload, mode)) {
                .streaming => |response| return .{ .streaming = response },
                .failure => |failure| {
                    // A transfer that broke partway is worth another try; a
                    // refused connection is not ours to retry.
                    if (failure == .transfer_failed and mode == .complete and
                        attempts < self.options.transfer_attempts)
                    {
                        continue;
                    }
                    // Neither of these is about this request: libcurl cannot be
                    // used, or the endpoint does not serve the required HTTP/2.
                    // Both stick, so nothing further is sent.
                    if (failure == .setup_failed or failure == .endpoint_broken)
                        self.broken = failure;
                    return .{ .failure = failure };
                },
            }
        }
    }

    /// One attempt: starts the transfer and waits for what `mode` needs.
    fn attempt(
        self: *Client,
        method: Method,
        url: []const u8,
        headers: []const Header,
        payload: ?[]const u8,
        mode: Mode,
    ) Outcome {
        const allocator = self.allocator;
        const io = self.io;

        const state = allocator.create(State) catch return .{ .failure = .out_of_memory };
        state.* = .{
            .allocator = allocator,
            .io = io,
            .log = self.options.log,
            .require_h2 = self.options.require_h2,
            .connect_timeout_ms = self.options.connect_timeout_ms,
            .idle_timeout_ms = self.options.idle_timeout_ms,
            .started_ns = nowNs(io),
        };
        // The transfer thread outlives this call, so it may not borrow.
        state.url = allocator.dupeSentinel(u8, url, 0) catch {
            state.deinit(allocator);
            return .{ .failure = .out_of_memory };
        };
        if (payload) |body| {
            state.payload = allocator.dupe(u8, body) catch {
                state.deinit(allocator);
                return .{ .failure = .out_of_memory };
            };
        }

        const response = allocator.create(Response) catch {
            state.deinit(allocator);
            return .{ .failure = .out_of_memory };
        };
        const buffer = allocator.alloc(u8, reader_buffer_len) catch {
            allocator.destroy(response);
            state.deinit(allocator);
            return .{ .failure = .out_of_memory };
        };
        response.* = .{
            .allocator = allocator,
            .state = state,
            .buffer = buffer,
            .reader_value = .{
                .vtable = &reader_vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .thread = undefined,
        };
        response.thread = std.Thread.spawn(.{}, run, .{ state, method, headers }) catch {
            allocator.free(buffer);
            allocator.destroy(response);
            state.deinit(allocator);
            return .{ .failure = .setup_failed };
        };

        // `stream` returns as soon as the head is known; `complete` waits for the
        // whole body, which is what makes a retry safe.
        state.mutex.lockUncancelable(io);
        if (mode == .stream) {
            while (!state.headers_ready and !state.done) state.cond.waitUncancelable(io, &state.mutex);
        } else {
            while (!state.done) state.cond.waitUncancelable(io, &state.mutex);
        }
        const failure = state.failure;
        state.mutex.unlock(io);
        if (failure) |state_failure| {
            response.deinit();
            return .{ .failure = state_failure };
        }
        return .{ .streaming = response };
    }
};

const State = struct {
    allocator: Allocator,
    io: Io,
    log: ?debug.Logger = null,
    require_h2: bool = false,
    connect_timeout_ms: ?u64 = null,
    idle_timeout_ms: ?u64 = null,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Owned; valid for the whole transfer because the thread outlives the call.
    url: ?[:0]u8 = null,
    payload: ?[]u8 = null,
    /// Raw CRLF-terminated header lines, as received.
    raw_headers: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    consumed: usize = 0,
    handle: ?*c.CURL = null,
    headers_ready: bool = false,
    done: bool = false,
    cancel: bool = false,
    cancelled: bool = false,
    failure: ?Failure = null,
    status: u16 = 0,
    http_version: c_long = 0,
    curl_code: c.CURLcode = c.CURLE_OK,
    errbuf: [c.CURL_ERROR_SIZE]u8 = @splat(0),

    // Measurements, all nanoseconds since `started_ns`; -1 means never reached.
    started_ns: i96 = 0,
    headers_ns: i96 = -1,
    first_byte_ns: i96 = -1,
    last_byte_ns: i96 = 0,
    max_stall_ns: i96 = 0,
    total_ns: i96 = -1,
    bytes: usize = 0,

    fn deinit(self: *State, allocator: Allocator) void {
        if (self.url) |u| allocator.free(u);
        if (self.payload) |body| allocator.free(body);
        self.raw_headers.deinit(allocator);
        self.body.deinit(allocator);
        allocator.destroy(self);
    }
};

/// The reader's own buffer. `Io.Reader` only reaches `stream` for an empty
/// buffer; every buffered entry point (`peek`, `takeDelimiter`, and so
/// `std.json`) first rebases into `buffer`, so a reader with none panics in
/// `defaultRebase` the moment one of them asks for a byte. The body arrives in
/// `State`; this only bounds what one `fill` may hold.
const reader_buffer_len = 16 << 10;

pub const Response = struct {
    allocator: Allocator,
    state: *State,
    /// Backs `reader_value`; freed in `deinit`.
    buffer: []u8,
    reader_value: Io.Reader,
    thread: std.Thread,

    pub fn deinit(self: *Response) void {
        const allocator = self.allocator;
        const io = self.state.io;
        self.state.mutex.lockUncancelable(io);
        self.state.cancel = true;
        self.state.cancelled = true;
        self.state.cond.broadcast(io);
        self.state.mutex.unlock(io);
        self.thread.join();
        allocator.free(self.buffer);
        self.state.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn status(self: *const Response) u16 {
        return self.state.status;
    }

    /// The state the transfer ended in, or null while it is still running or
    /// ended cleanly. A cancelled stream ends as `Failure.cancelled`, which is
    /// how a caller tells an abandoned body from a finished one.
    pub fn failure(self: *const Response) ?Failure {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        return state.failure;
    }

    /// Names compare case-insensitively. The returned slice is owned by the
    /// response.
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        const state = self.state;
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        var lines = std.mem.splitSequence(u8, state.raw_headers.items, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        return null;
    }

    /// Reads the response body as it arrives; blocks until bytes are available
    /// or the transfer ends.
    pub fn reader(self: *Response) *Io.Reader {
        return &self.reader_value;
    }
};

// ---------------------------------------------------------------------------
// libcurl lifetime
// ---------------------------------------------------------------------------

var global_mutex: Io.Mutex = .init;
var global_ready = false;

fn initGlobal(io: Io) bool {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);
    if (global_ready) return true;
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return false;
    global_ready = true;
    return true;
}

fn nowNs(io: Io) i96 {
    return Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

// ---------------------------------------------------------------------------
// The transfer thread
// ---------------------------------------------------------------------------

fn run(state: *State, method: Method, headers: []const Header) void {
    transfer(state, method, headers);

    state.mutex.lockUncancelable(state.io);
    state.done = true;
    state.total_ns = nowNs(state.io) - state.started_ns;
    if (state.failure == null) {
        // A cancel aborts the transfer too, so it is decided before the
        // generic code mapping; otherwise it would read as a failure.
        if (state.cancelled) {
            state.failure = .cancelled;
        } else if (state.curl_code == c.CURLE_OUT_OF_MEMORY) {
            state.failure = .out_of_memory;
        } else if (state.curl_code != c.CURLE_OK) {
            state.failure = if (state.headers_ready) .transfer_failed else .connect_failed;
        }
    }
    state.cond.broadcast(state.io);
    state.mutex.unlock(state.io);

    logRequest(state);
}

/// Runs the easy handle. Every failure it can produce is recorded on `state`;
/// `run` turns that into the done flag and the log line.
fn transfer(state: *State, method: Method, headers: []const Header) void {
    const allocator = state.allocator;
    const handle = c.curl_easy_init() orelse return note(state, .setup_failed);
    defer c.curl_easy_cleanup(handle);
    state.handle = handle;

    var slist: ?*c.curl_slist = null;
    defer if (slist) |list| c.curl_slist_free_all(list);
    for (headers) |header| {
        const line = std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ header.name, header.value }, 0) catch
            return note(state, .out_of_memory);
        defer allocator.free(line);
        slist = c.curl_slist_append(slist, line.ptr) orelse return note(state, .out_of_memory);
    }

    setopt(handle, c.CURLOPT_URL, (state.url orelse return note(state, .setup_failed)).ptr) catch
        return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_2TLS)) catch
        return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1)) catch return note(state, .setup_failed);
    if (slist) |list| setopt(handle, c.CURLOPT_HTTPHEADER, list) catch return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_WRITEFUNCTION, writeCallback) catch return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_WRITEDATA, state) catch return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_HEADERFUNCTION, headerCallback) catch return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_HEADERDATA, state) catch return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_ERRORBUFFER, &state.errbuf) catch return note(state, .setup_failed);
    // The progress callback is the only hook that runs while a transfer is
    // stalled, so it is where an abort is noticed during a silent connect.
    setopt(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 0)) catch return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_XFERINFOFUNCTION, progressCallback) catch return note(state, .setup_failed);
    setopt(handle, c.CURLOPT_XFERINFODATA, state) catch return note(state, .setup_failed);

    if (state.connect_timeout_ms) |limit| {
        setopt(handle, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(limit))) catch
            return note(state, .setup_failed);
    }
    if (state.idle_timeout_ms) |limit| {
        // A stall this long aborts. libcurl counts seconds, so a bound under a
        // second rounds up to one.
        setopt(handle, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1)) catch return note(state, .setup_failed);
        setopt(handle, c.CURLOPT_LOW_SPEED_TIME, @as(c_long, @intCast(@max(1, (limit + 999) / 1000)))) catch
            return note(state, .setup_failed);
    }

    switch (method) {
        .GET => setopt(handle, c.CURLOPT_HTTPGET, @as(c_long, 1)) catch return note(state, .setup_failed),
        .POST => {
            const body = state.payload orelse return note(state, .setup_failed);
            setopt(handle, c.CURLOPT_POST, @as(c_long, 1)) catch return note(state, .setup_failed);
            setopt(handle, c.CURLOPT_POSTFIELDS, body.ptr) catch return note(state, .setup_failed);
            setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len))) catch
                return note(state, .setup_failed);
        },
    }

    state.curl_code = c.curl_easy_perform(handle);
}

/// Only the transfer thread writes a failure before `done`, so no lock is
/// needed here; the reader and `deinit` see it through `done`'s lock.
fn note(state: *State, failure: Failure) void {
    state.failure = failure;
}

fn logRequest(state: *State) void {
    const log = state.log orelse return;
    if (state.failure) |failure| {
        log.report("http:failed", "state={s} code={d} reason={s} detail={s} connect={d}ms ttfb={d}ms stall={d}ms total={d}ms bytes={d}", .{
            @tagName(failure),
            @as(c_int, @intCast(state.curl_code)),
            std.mem.span(c.curl_easy_strerror(state.curl_code)),
            std.mem.sliceTo(&state.errbuf, 0),
            toMs(state.headers_ns),
            toMs(state.first_byte_ns),
            toMs(state.max_stall_ns),
            toMs(state.total_ns),
            state.bytes,
        });
        return;
    }
    log.report("http:done", "status={d} version={s} connect={d}ms ttfb={d}ms stall={d}ms total={d}ms bytes={d}", .{
        state.status,
        versionName(state.http_version),
        toMs(state.headers_ns),
        toMs(state.first_byte_ns),
        toMs(state.max_stall_ns),
        toMs(state.total_ns),
        state.bytes,
    });
}

fn toMs(ns: i96) i64 {
    if (ns < 0) return -1;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn versionName(v: c_long) []const u8 {
    return switch (v) {
        c.CURL_HTTP_VERSION_1_0 => "1.0",
        c.CURL_HTTP_VERSION_1_1 => "1.1",
        c.CURL_HTTP_VERSION_2_0 => "h2",
        c.CURL_HTTP_VERSION_3 => "h3",
        else => "?",
    };
}

// ---------------------------------------------------------------------------
// libcurl callbacks
// ---------------------------------------------------------------------------

fn writeCallback(data: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const total = size * nmemb;
    const state: *State = @ptrCast(@alignCast(userdata.?));
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (state.cancel) return 0;

    const now = nowNs(state.io);
    if (state.first_byte_ns < 0) {
        state.first_byte_ns = now - state.started_ns;
    } else {
        // Only gaps between body bytes count as stalls; the wait for the first
        // one is `ttfb`, which is a different bound.
        const gap = now - state.last_byte_ns;
        if (gap > state.max_stall_ns) state.max_stall_ns = gap;
    }
    state.last_byte_ns = now;

    state.body.appendSlice(state.allocator, data[0..total]) catch {
        state.failure = .out_of_memory;
        state.cond.broadcast(state.io);
        return 0;
    };
    state.bytes += total;
    state.cond.broadcast(state.io);
    return total;
}

/// Returns non-zero to abort the transfer, which is how a cancel from
/// `Response.deinit` reaches a transfer that is not producing body bytes.
fn progressCallback(
    clientp: ?*anyopaque,
    dltotal: c.curl_off_t,
    dlnow: c.curl_off_t,
    ultotal: c.curl_off_t,
    ulnow: c.curl_off_t,
) callconv(.c) c_int {
    _ = .{ dltotal, dlnow, ultotal, ulnow };
    const state: *State = @ptrCast(@alignCast(clientp.?));
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    if (!state.cancel) return 0;
    state.cancelled = true;
    return 1;
}

fn headerCallback(data: [*c]const u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const total = size * nmemb;
    const state: *State = @ptrCast(@alignCast(userdata.?));
    if (!onHeader(state, data[0..total])) return 0;
    return total;
}

/// Returns false to abort the transfer, which the header callback turns into a
/// zero return.
fn onHeader(self: *State, bytes: []const u8) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (std.mem.startsWith(u8, bytes, "HTTP/")) {
        self.status = parseStatus(bytes) orelse {
            self.failure = .transfer_failed;
            self.cond.broadcast(self.io);
            return false;
        };
        var version: c_long = 0;
        if (self.handle) |handle| _ = c.curl_easy_getinfo(handle, c.CURLINFO_HTTP_VERSION, &version);
        self.http_version = version;
        self.headers_ns = nowNs(self.io) - self.started_ns;
        self.headers_ready = true;
        if (self.require_h2 and version != c.CURL_HTTP_VERSION_2_0) {
            self.failure = .endpoint_broken;
            self.cond.broadcast(self.io);
            return false;
        }
        self.cond.broadcast(self.io);
        return true;
    }

    self.raw_headers.appendSlice(self.allocator, bytes) catch {
        self.failure = .out_of_memory;
        self.cond.broadcast(self.io);
        return false;
    };
    return true;
}

fn parseStatus(line: []const u8) ?u16 {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    _ = parts.next() orelse return null;
    const code = parts.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn setopt(handle: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(handle, option, value) != c.CURLE_OK) return error.SetOptFailed;
}

// ---------------------------------------------------------------------------
// The blocking reader
// ---------------------------------------------------------------------------

const reader_vtable: Io.Reader.VTable = .{
    .stream = readerStream,
};

fn readerStream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const self: *Response = @fieldParentPtr("reader_value", r);
    const state = self.state;
    const capacity = @backingInt(limit);
    if (capacity == 0) return 0;

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    while (state.consumed == state.body.items.len and !state.done and !state.cancel) {
        state.cond.waitUncancelable(state.io, &state.mutex);
    }
    if (state.consumed == state.body.items.len) {
        // The end of the body is `error.EndOfStream`, not a zero return: a
        // zero return means "nothing yet", and a caller looping until the
        // buffer fills would spin on it forever. A cancelled or failed
        // transfer ends as a read failure instead.
        if (state.failure != null) return error.ReadFailed;
        return error.EndOfStream;
    }

    const available = state.body.items[state.consumed..];
    const n = @min(available.len, capacity);
    const written = w.write(available[0..n]) catch return error.WriteFailed;
    state.consumed += written;

    // Drop what has been consumed so a long stream does not accumulate.
    if (state.consumed > 64 << 10) {
        std.mem.copyForwards(u8, state.body.items[0..], state.body.items[state.consumed..]);
        state.body.shrinkRetainingCapacity(state.body.items.len - state.consumed);
        state.consumed = 0;
    }
    return written;
}