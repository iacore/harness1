//! Probes how LithosAI accepts image and video input.
//!
//! A scratch program like `lithos_probe`: it needs a key and a network, so it
//! is neither installed nor built by the default step.
//!
//!   zig build --build-file ./build.research.zig lithos_media
//!
//! `src/remote/lithos.zig` models one media part, `image_url`, and the vendor's
//! OpenAPI reference documents no part schema at all — its message leaves
//! `content` as a bare `string|array|null`. So the ways to carry an image,
//! video or audio are measured, not read: a URL reference against a base64
//! data URL, and the part shapes Chat Completions does not define (`video_url`,
//! `input_audio`, `audio_url`, `input_video`, `file`).
//!
//! Every case is answerable only by having seen the media, so a 200 with the
//! right answer is the evidence and a 400 is a refusal. The probe speaks raw
//! HTTP for shapes `chat.Message` cannot express, and sends one case through
//! the client itself so the typed path is exercised end to end.
//!
//! Findings belong in `research/lithos.dj` and `src/remote/lithos_models.md`.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Allocator = std.mem.Allocator;
const run1 = @import("run1");
const lithos = run1.lithos;
const chat = lithos.chat;
const keys = run1.keys;
const debug = run1.debug;

const endpoint = "https://api.lithosai.cloud/v1/chat/completions";

/// A black puppy, reachable from anywhere, so the loader fetches a real image.
const image_url = "https://picsum.photos/id/237/320/240.jpg";
/// Big Buck Bunny, 360p, ~1 MB — small enough to fetch, a real MP4.
const video_url = "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4";
/// A 3-second MP3, reachable from anywhere, for the audio_url arm.
const audio_url = "https://download.samplelib.com/mp3/sample-3s.mp3";

const models = [_][]const u8{
    "deepseek-ai/DeepSeek-V4.1-Flash",
    "moonshotai/Kimi-K3",
};

/// How a case carries its media. One arm per shape worth trying; the first
/// three are documented by every other OpenAI-wire host, the rest are not.
const Carrier = enum {
    image_url_ref,
    image_url_data,
    image_url_ref_detail,
    video_as_image_url_ref,
    video_as_image_url_data,
    video_url_ref,
    video_url_data,
    video_url_unreachable,
    input_video_ref,
    file_video_ref,
    audio_input_data,
    audio_url_ref,
    file_id_ref,
};

const Case = struct {
    carrier: Carrier,
    question: []const u8,
};

/// Our own image says `ZEBRA 42`; the remote one is a puppy; the clips are Big
/// Buck Bunny. Each question is answerable only from the media, so the answer
/// is the discriminator and the status alone is not.
const question_zebra = "Transcribe the exact text in this image. Reply with only that text.";
const question_animal = "What animal is in this photo? Reply with one word.";
const question_video = "Describe in one short sentence what this video shows.";
/// Answerable only from the clip: Big Buck Bunny's star is a rabbit, so any
/// other answer is the model working from the prompt alone.
const question_video_animal = "What animal is the main character of this video? Reply with one word.";
const question_audio = "Describe in one short sentence what you hear.";

const cases = [_]Case{
    .{ .carrier = .image_url_ref, .question = question_animal },
    .{ .carrier = .image_url_data, .question = question_zebra },
    .{ .carrier = .image_url_ref_detail, .question = question_animal },
    .{ .carrier = .video_as_image_url_ref, .question = question_video },
    .{ .carrier = .video_as_image_url_data, .question = question_video },
    .{ .carrier = .video_url_ref, .question = question_video_animal },
    .{ .carrier = .video_url_data, .question = question_video },
    .{ .carrier = .video_url_unreachable, .question = question_video_animal },
    .{ .carrier = .input_video_ref, .question = question_video },
    .{ .carrier = .file_video_ref, .question = question_video },
    .{ .carrier = .audio_input_data, .question = question_audio },
    .{ .carrier = .audio_url_ref, .question = question_audio },
    .{ .carrier = .file_id_ref, .question = question_video },
};

const Assets = struct {
    /// `data:image/png;base64,...` of `media/probe.png`.
    image_data: []const u8,
    /// `data:video/mp4;base64,...` of `media/probe.mp4`.
    video_data: []const u8,
    /// `data:audio/wav;base64,...` of `media/probe.wav`.
    audio_data: []const u8,
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

    const png = try Io.Dir.cwd().readFileAlloc(io, "research/lithos/media/probe.png", arena, .limited(1 << 20));
    const mp4 = try Io.Dir.cwd().readFileAlloc(io, "research/lithos/media/probe.mp4", arena, .limited(1 << 20));
    const wav = try Io.Dir.cwd().readFileAlloc(io, "research/lithos/media/probe.wav", arena, .limited(1 << 20));
    const assets: Assets = .{
        .image_data = try dataUrl(arena, "image/png", png),
        .video_data = try dataUrl(arena, "video/mp4", mp4),
        .audio_data = try dataUrl(arena, "audio/wav", wav),
    };

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    for (models) |model| {
        try out.print("model: {s}\n", .{model});
        // Control: no media at all, so a healthy endpoint is distinguished from
        // a broken key before the media cases are read.
        try raw(&client, arena, out, api_key, model, "text control", "\"Tell me one word: the colour of the sky at noon.\"");
        for (cases) |case| {
            const part = try partJson(arena, case.carrier, assets);
            const content = try std.fmt.allocPrint(
                arena,
                "[{s},{{\"type\":\"text\",\"text\":\"{s}\"}}]",
                .{ part, case.question },
            );
            try raw(&client, arena, out, api_key, model, @tagName(case.carrier), content);
        }
        try out.writeByte('\n');
    }

    // The typed path: `chat.Part.image_url` carrying the inline image, with no
    // raw JSON anywhere, for each model.
    var lithos_client = try lithos.Client.init(gpa, io, api_key, .{});
    defer lithos_client.deinit();
    for (models) |model| {
        try typed(&lithos_client, out, model, assets.image_data);
    }

    try out.flush();
}

/// `null` when `carrier` is the control: the case is then sent as a plain text
/// message.
fn partJson(arena: Allocator, carrier: Carrier, assets: Assets) ![]const u8 {
    return switch (carrier) {
        .image_url_ref => std.fmt.allocPrint(arena, "{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"{s}\"}}}}", .{image_url}),
        .image_url_data => std.fmt.allocPrint(arena, "{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"{s}\"}}}}", .{assets.image_data}),
        .image_url_ref_detail => std.fmt.allocPrint(arena, "{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"{s}\",\"detail\":\"high\"}}}}", .{image_url}),
        .video_as_image_url_ref => std.fmt.allocPrint(arena, "{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"{s}\"}}}}", .{video_url}),
        .video_as_image_url_data => std.fmt.allocPrint(arena, "{{\"type\":\"image_url\",\"image_url\":{{\"url\":\"{s}\"}}}}", .{assets.video_data}),
        .video_url_ref => std.fmt.allocPrint(arena, "{{\"type\":\"video_url\",\"video_url\":{{\"url\":\"{s}\"}}}}", .{video_url}),
        .video_url_data => std.fmt.allocPrint(arena, "{{\"type\":\"video_url\",\"video_url\":{{\"url\":\"{s}\"}}}}", .{assets.video_data}),
        .video_url_unreachable => std.fmt.allocPrint(arena, "{{\"type\":\"video_url\",\"video_url\":{{\"url\":\"{s}\"}}}}", .{"https://example.com/nope.mp4"}),
        .input_video_ref => std.fmt.allocPrint(arena, "{{\"type\":\"input_video\",\"video_url\":{{\"url\":\"{s}\"}}}}", .{video_url}),
        .file_video_ref => std.fmt.allocPrint(arena, "{{\"type\":\"file\",\"file\":{{\"file_url\":\"{s}\"}}}}", .{video_url}),
        .audio_input_data => std.fmt.allocPrint(arena, "{{\"type\":\"input_audio\",\"input_audio\":{{\"data\":\"{s}\",\"format\":\"wav\"}}}}", .{assets.audio_data}),
        .audio_url_ref => std.fmt.allocPrint(arena, "{{\"type\":\"audio_url\",\"audio_url\":{{\"url\":\"{s}\"}}}}", .{audio_url}),
        .file_id_ref => std.fmt.allocPrint(arena, "{{\"type\":\"file\",\"file\":{{\"file_id\":\"{s}\"}}}}", .{"file-abc"}),
    };
}

fn dataUrl(arena: Allocator, mime: []const u8, bytes: []const u8) ![]const u8 {
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ mime, encoded });
}

/// `content_json` is the raw JSON of the user message's `content` — a quoted
/// string for the control, an array of parts otherwise — so shapes the types
/// cannot express are sent as written.
fn raw(
    client: *http.Client,
    arena: Allocator,
    out: *Io.Writer,
    api_key: []const u8,
    model: []const u8,
    label: []const u8,
    content_json: []const u8,
) !void {
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":{s}}}],\"reasoning_effort\":\"none\",\"max_tokens\":96}}",
        .{ model, content_json },
    );

    const gpa = client.allocator;
    const uri = try std.Uri.parse(endpoint);
    const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});
    defer gpa.free(bearer);
    const headers = [_]http.Header{
        .{ .name = "authorization", .value = bearer },
        .{ .name = "content-type", .value = "application/json" },
    };

    var request = client.request(.POST, uri, .{ .extra_headers = &headers, .redirect_behavior = .not_allowed }) catch |err| {
        try out.print("  {s:<26} transport {s}\n", .{ label, @errorName(err) });
        return;
    };
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    var payload = try request.sendBody(&.{});
    payload.writer.writeAll(body) catch |err| {
        try out.print("  {s:<26} write {s}\n", .{ label, @errorName(err) });
        return;
    };
    payload.end() catch |err| {
        try out.print("  {s:<26} write {s}\n", .{ label, @errorName(err) });
        return;
    };
    request.connection.?.flush() catch {};

    var head = request.receiveHead(&.{}) catch |err| {
        try out.print("  {s:<26} read {s}\n", .{ label, @errorName(err) });
        return;
    };
    const status: u16 = @backingInt(head.head.status);

    var buffer: [256 << 10]u8 = undefined;
    var transfer: [512]u8 = undefined;
    const length = readUpTo(head.reader(&transfer), &buffer);
    const text = buffer[0..length];

    try out.print("  {s:<26} HTTP {d}", .{ label, status });
    if (answerOf(arena, text)) |answer| {
        try out.writeAll("  answer: ");
        try oneLine(out, answer, 200);
    } else if (errorOf(arena, text)) |message| {
        try out.writeAll("  error: ");
        try oneLine(out, message, 200);
    } else {
        try out.writeAll("  body: ");
        try oneLine(out, text, 200);
    }
    try out.writeByte('\n');
    try out.flush();
}

/// One request through the typed client, with an inline image and no raw JSON,
/// so the client's own encoder is exercised on the media path. It streams and
/// collects rather than using `chat.send`, because on this checkout the
/// non-streaming path panics inside the transport's bufferless reader (see the
/// note in research/lithos.dj); streaming reads the body a line at a time and
/// does not.
fn typed(client: *lithos.Client, out: *Io.Writer, model: []const u8, image_data: []const u8) !void {
    const parts = [_]chat.Part{
        .{ .image_url = .{ .url = image_data } },
        .{ .text = question_zebra },
    };
    const messages = [_]chat.Message{
        .{ .user = .{ .content = .{ .parts = &parts } } },
    };
    try out.print("client(stream) {s:<30} ", .{model});
    const result = chat.sendStream(client, &.{
        .model = model,
        .messages = &messages,
        .reasoning_effort = .{ .named = .none },
        .max_tokens = 96,
    }) catch |err| {
        try out.print("transport {s}\n", .{@errorName(err)});
        return;
    };
    switch (result) {
        .ok => |stream_value| {
            var stream = stream_value;
            defer stream.deinit();
            var collected = try stream.collect(client.allocator);
            defer collected.deinit();
            const message = collected.value.message();
            const answer = if (message.content) |content| content else "";
            try out.writeAll("HTTP 200  answer: ");
            try oneLine(out, answer, 200);
            try out.writeByte('\n');
        },
        .err => |failure| {
            try out.writeAll("failure: ");
            try failure.format(out);
            try out.writeByte('\n');
        },
    }
    try out.flush();
}

fn answerOf(arena: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const choices = switch (root.get("choices") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (choices.items.len == 0) return null;
    const first = switch (choices.items[0]) {
        .object => |o| o,
        else => return null,
    };
    const message = switch (first.get("message") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (message.get("content") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn errorOf(arena: Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    if (root.get("error")) |error_value| switch (error_value) {
        .object => |o| return switch (o.get("message") orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => {},
    };
    return switch (root.get("message") orelse return null) {
        .string => |s| s,
        else => null,
    };
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

fn oneLine(out: *Io.Writer, bytes: []const u8, limit: usize) !void {
    var shown: usize = 0;
    for (bytes) |c| {
        if (shown >= limit) {
            try out.writeAll(" ...");
            return;
        }
        try out.writeByte(if (c == '\n' or c == '\r') ' ' else c);
        shown += 1;
    }
}