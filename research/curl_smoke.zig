//! Exercises the libcurl transport in `src/curl.zig` and the LithosAI client
//! built on it.
//!
//!   zig build --build-file ./build.research.zig curl_smoke
//!
//! No key is needed: the endpoint answers an unauthenticated 401, which still
//! proves HTTP/2 was negotiated and the body reached the reader.

const std = @import("std");
const Io = std.Io;
const harness1 = @import("harness1");
const curl = harness1.curl;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;
    const log = harness1.debug.writer(out);

    // 1 and 3: an endpoint that serves h2, with h2 required.
    var client = curl.Client.init(gpa, io, .{ .require_h2 = true, .log = log });
    defer client.deinit();
    try report(gpa, out, "lithos ", client.request(.GET, "https://api.lithosai.cloud/v1/models", &.{}, null, .complete));
    try report(gpa, out, "httpbin", client.request(.GET, "https://httpbin.org/bytes/131072", &.{}, null, .complete));

    // 2: an HTTP/1.1-only endpoint breaks the client, and it stays broken —
    //    the second request is never sent.
    {
        var only_h1 = curl.Client.init(gpa, io, .{ .require_h2 = true, .log = log });
        defer only_h1.deinit();
        try report(gpa, out, "mit.edu", only_h1.request(.GET, "https://www.mit.edu/", &.{}, null, .complete));
        try report(gpa, out, "mit.edu", only_h1.request(.GET, "https://www.mit.edu/", &.{}, null, .complete));
    }

    // 4: the LithosAI client end to end. A dummy key gets the API's own 401
    //    envelope, which it can only reach over a connection that stayed h2.
    {
        var lithos = try harness1.lithos.Client.init(gpa, io, "dummy", .{ .require_h2 = true, .log = log });
        defer lithos.deinit();
        switch (try harness1.lithos.models.list(&lithos)) {
            .ok => |parsed| {
                var p = parsed;
                p.deinit();
                try out.print("client : UNEXPECTED ok\n", .{});
            },
            .err => |failure| {
                if (failure == .api) {
                    var envelope = failure.api;
                    defer envelope.deinit(gpa);
                    try out.print("client : api status={d} type={s} message={s}\n", .{
                        envelope.status_code, envelope.type, envelope.message,
                    });
                } else {
                    try out.print("client : {s}\n", .{@tagName(std.meta.activeTag(failure))});
                }
            },
        }
    }

    // 5: cancelling mid-transfer is visible, as `Cancelled` rather than a
    //    clean end.
    switch (client.request(.GET, "https://httpbin.org/drip?duration=5&numbytes=50", &.{}, null, .stream)) {
        .streaming => |response| {
            response.deinit();
            try out.print("cancel : deinit returned\n", .{});
        },
        .failure => |failure| try out.print("cancel : {s}\n", .{@tagName(failure)}),
    }

    // 6: a body that stops arriving trips the idle bound. That is a transfer
    //    failure, so it gets `transfer_attempts` tries before being reported —
    //    watch for exactly three `http:failed` lines.
    {
        var stalling = curl.Client.init(gpa, io, .{
            .require_h2 = true,
            .idle_timeout_ms = 1000,
            .log = log,
        });
        defer stalling.deinit();
        try report(gpa, out, "stall  ", stalling.request(
            .GET,
            "https://httpbin.org/drip?duration=20&numbytes=5",
            &.{},
            null,
            .complete,
        ));
    }

    // 7: a connection that never comes up is not retried — exactly one
    //    `http:failed` line, and the state goes back to the caller so a person
    //    can decide whether to try again.
    try report(gpa, out, "no-such", client.request(.GET, "https://no-such-host.invalid/", &.{}, null, .complete));

    try out.flush();
}

fn report(gpa: std.mem.Allocator, out: *Io.Writer, label: []const u8, outcome: curl.Outcome) !void {
    switch (outcome) {
        .streaming => |response| {
            defer response.deinit();
            const body = try readAll(gpa, response.reader());
            defer gpa.free(body);
            try out.print("{s}: status={d} bytes={d}\n", .{ label, response.status(), body.len });
        },
        .failure => |failure| try out.print("{s}: {s}\n", .{ label, @tagName(failure) }),
    }
}

fn readAll(gpa: std.mem.Allocator, reader: *Io.Reader) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buffer: [4096]u8 = undefined;
    while (true) {
        var w = Io.Writer.fixed(&buffer);
        const n = reader.stream(&w, .limited(buffer.len)) catch break;
        if (n == 0) break;
        try list.appendSlice(gpa, w.buffered());
    }
    return list.toOwnedSlice(gpa);
}