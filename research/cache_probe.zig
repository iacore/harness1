//! Measures whether prompt caching needs a *fixed prefix*, by sending the same
//! conversation with one turn edited each time and printing each response's
//! `usage` object.
//!
//!   zig build --build-file ./build.research.zig cache_probe
//!
//! The filler is random per run, so nothing is cached across runs and the first
//! request is a genuine cold miss. Variants: a prime, the same prompt again, and
//! then last / middle / first turn edited — which separates "the prefix is
//! cached" from "the whole prompt is cached".

const std = @import("std");
const Io = std.Io;
const http = std.http;
const run1 = @import("run1");
const keys = run1.keys;
const debug = run1.debug;

const endpoint = "https://api.lithosai.cloud/v1/chat/completions";
const model = "deepseek-ai/DeepSeek-V4.1-Flash";
const turns = 8;
/// Hex characters per turn, so each turn is ~4 KB of unique ASCII.
const chars_per_turn = 4096;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr().writerStreaming(io, &stderr_buffer);

    const api_key = try keys.apiKey(arena, io, debug.writer(&stderr_file.interface), init.environ_map, keys.Provider.lithosai) orelse
        return error.ApiKeyRequired;

    // One random block, sliced per turn so every turn differs from every other.
    // One spare turn of filler, so an edited turn's shifted slice stays in range.
    const raw = try arena.alloc(u8, (turns + 1) * chars_per_turn / 2);
    Io.random(io, raw);
    const filler = try arena.alloc(u8, raw.len * 2);
    _ = std.fmt.bufPrint(filler, "{x}", .{raw}) catch unreachable;

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const Case = struct {
        label: []const u8,
        /// Turn indices whose content is replaced, 0-based.
        edited: []const usize,
    };
    // Every case is sent twice, because consecutive requests are routed by
    // llm-d and may land on different replicas with different caches. A second
    // send of identical bytes is the control: if it does not hit, the route is
    // the variable, not the edit.
    const cases = [_]Case{
        .{ .label = "base", .edited = &.{} },
        .{ .label = "base again", .edited = &.{} },
        .{ .label = "last edited", .edited = &.{turns - 1} },
        .{ .label = "last edited again", .edited = &.{turns - 1} },
        .{ .label = "middle edited", .edited = &.{turns / 2 - 1} },
        .{ .label = "middle edited again", .edited = &.{turns / 2 - 1} },
        .{ .label = "first edited", .edited = &.{0} },
        .{ .label = "first edited again", .edited = &.{0} },
    };

    for (cases) |case| {
        const body = try buildBody(arena, filler, case.edited);
        const usage = try post(arena, &client, out, api_key, body);
        try out.print("{s:<20} {s}\n", .{ case.label, usage });
        try out.flush();
    }
}

/// A chat body of `turns` user messages, each a slice of `filler`. `edited`
/// turns get a different slice, which changes the bytes from that turn on.
fn buildBody(arena: std.mem.Allocator, filler: []const u8, edited: []const usize) ![]u8 {
    const chunk = chars_per_turn;
    var allocating: Io.Writer.Allocating = .init(arena);
    errdefer allocating.deinit();
    const w = &allocating.writer;
    try w.print("{{\"model\":\"{s}\",\"reasoning_effort\":\"none\",\"max_tokens\":1,\"messages\":[", .{model});
    for (0..turns) |i| {
        if (i != 0) try w.writeAll(",");
        var is_edited = false;
        for (edited) |e| {
            if (e == i) is_edited = true;
        }
        const shift: usize = if (is_edited) chunk / 2 else 0;
        const start = i * chunk;
        const text = filler[start + shift .. start + shift + chunk];
        try w.print("{{\"role\":\"user\",\"content\":\"turn {d}: {s}\"}}", .{ i, text });
    }
    try w.writeAll("]}");
    return allocating.toOwnedSlice();
}

/// Sends one request and returns its `usage` object rendered as text.
fn post(
    arena: std.mem.Allocator,
    client: *http.Client,
    out: *Io.Writer,
    api_key: []const u8,
    body: []const u8,
) ![]const u8 {
    _ = out;
    const uri = try std.Uri.parse(endpoint);
    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key});
    const headers = [_]http.Header{
        .{ .name = "authorization", .value = bearer },
        .{ .name = "content-type", .value = "application/json" },
    };

    var request = try client.request(.POST, uri, .{
        .extra_headers = &headers,
        .redirect_behavior = .not_allowed,
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var payload = try request.sendBody(&.{});
    try payload.writer.writeAll(body);
    try payload.end();
    try request.connection.?.flush();

    var head = try request.receiveHead(&.{});
    var buffer: [1 << 20]u8 = undefined;
    var transfer: [512]u8 = undefined;
    const length = readUpTo(head.reader(&transfer), &buffer);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, buffer[0..length], .{ .ignore_unknown_fields = true });
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return "not an object",
    };
    if (root.get("usage")) |usage| {
        return try std.json.Stringify.valueAlloc(arena, usage, .{});
    }
    return buffer[0..length];
}

fn readUpTo(reader: *Io.Reader, buffer: []u8) usize {
    var writer = Io.Writer.fixed(buffer);
    var length: usize = 0;
    while (length < buffer.len) {
        const n = reader.stream(&writer, .limited(buffer.len - length)) catch break;
        length += n;
    }
    return length;
}