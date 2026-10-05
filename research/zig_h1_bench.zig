//! Times N concurrent HTTP/1.1 requests from `std.http.Client`, so its h1
//! stack can be compared with curl's on the same endpoint.
//!
//!   zig build --build-file ./build.research.zig zig_h1_bench -- 20
//!
//! `std.http.Client` sends no ALPN, so the server answers HTTP/1.1; each
//! in-flight request needs its own connection, exactly as curl does.

const std = @import("std");
const Io = std.Io;
const http = std.http;

const url = "https://api.lithosai.cloud/v1/models";
const max_concurrency = 64;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;

    const args = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    const concurrency = if (args.len > 1)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        10;
    if (concurrency == 0 or concurrency > max_concurrency) return error.BadConcurrency;

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var latencies: [max_concurrency]i96 = undefined;
    var statuses: [max_concurrency]u16 = undefined;
    var threads: [max_concurrency]std.Thread = undefined;

    const start = Io.Clock.Timestamp.now(io, .awake);
    for (0..concurrency) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{ &client, io, uri, &latencies[i], &statuses[i] });
    }
    for (threads[0..concurrency]) |t| t.join();
    const wall_ns = start.untilNow(io).raw.nanoseconds;

    std.mem.sort(i96, latencies[0..concurrency], {}, std.sort.asc(i96));
    try out.print("concurrency={d}  wall={d}ms  min={d} median={d} max={d}  first_status={d}\n", .{
        concurrency,
        ms(wall_ns),
        ms(latencies[0]),
        ms(latencies[concurrency / 2]),
        ms(latencies[concurrency - 1]),
        statuses[0],
    });
    try out.flush();
}

fn ms(ns: i96) u64 {
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn worker(client: *http.Client, io: Io, uri: std.Uri, latency: *i96, status: *u16) void {
    const start = Io.Clock.Timestamp.now(io, .awake);
    defer latency.* = start.untilNow(io).raw.nanoseconds;

    var req = client.request(.GET, uri, .{ .redirect_behavior = .not_allowed }) catch return;
    defer req.deinit();
    req.sendBodiless() catch return;
    var head = req.receiveHead(&.{}) catch return;
    status.* = @backingInt(head.head.status);

    var transfer: [512]u8 = undefined;
    var sink_buffer: [4096]u8 = undefined;
    var sink = Io.Writer.fixed(&sink_buffer);
    _ = head.reader(&transfer).stream(&sink, .limited(sink_buffer.len)) catch {};
}