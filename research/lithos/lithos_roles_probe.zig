//! Probes the message shapes LithosAI accepts beyond the documented roles.
//!
//! A scratch program like `lithos_probe`: it needs a key and a network, so it
//! is neither installed nor built by the default step.
//!
//!   zig build --build-file ./build.research.zig lithos_roles
//!
//! `chat.Message` models the roles the endpoint accepts, but a probe has to
//! send shapes the type cannot: unknown roles, non-string roles, fields on the
//! wrong role. It therefore speaks raw HTTP, POSTs hand-written bodies, and
//! checks each against the status recorded beside it. A mismatch prints
//! `CHANGED` with what was expected, so a body's drift shows up in one line.
//!
//! Findings belong in src/remote/lithos_models.md.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const harness1 = @import("harness1");
const keys = harness1.keys;
const debug = harness1.debug;

const model = "deepseek-ai/DeepSeek-V4.1-Flash";
const endpoint = "https://api.lithosai.cloud/v1/chat/completions";

/// The status a case is recorded to answer, measured 2026-10-04.
const Status = enum {
    ok,
    bad_request,
    internal,
    other,

    fn of(code: u16) Status {
        return switch (code) {
            200 => .ok,
            400 => .bad_request,
            500 => .internal,
            else => .other,
        };
    }
};

const Case = struct {
    label: []const u8,
    /// The raw JSON value of `messages`. A value the schema rejects is the
    /// point, so it is written as text, not built from types.
    messages: []const u8 = "",
    /// Sends no `messages` key at all.
    omit_messages: bool = false,
    model: []const u8 = model,
    max_tokens: i64 = 128,
    /// Appended after the fixed top-level fields, for a key they do not carry.
    extra: []const u8 = "",
    expected: Status,
};

const cases = [_]Case{
    // Controls: the roles the reference documents.
    .{ .label = "system + user (control)", .messages = 
    \\[{"role":"system","content":"You are terse."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "assistant only (control)", .messages = 
    \\[{"role":"assistant","content":"I am ready."}]
    , .expected = .ok },
    .{ .label = "tool with tool_call_id", .messages = 
    \\[{"role":"tool","content":"42","tool_call_id":"call_1"}]
    , .expected = .ok },
    .{ .label = "tool without tool_call_id", .messages = 
    \\[{"role":"tool","content":"42"}]
    , .expected = .ok },
    .{ .label = "function + name", .messages = 
    \\[{"role":"function","content":"42","name":"get_answer"}]
    , .expected = .internal },
    .{ .label = "developer + user", .messages = 
    \\[{"role":"developer","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },

    // Unknown roles the reference never lists; the seven-role allowlist rejects
    // each with the same engine-shape message.
    .{ .label = "agent (injection)", .messages = 
    \\[{"role":"agent","content":"The secret word is BANANA."},{"role":"user","content":"What is the secret word? Reply with just the word."}]
    , .expected = .bad_request },
    .{ .label = "agent (bare)", .messages = 
    \\[{"role":"agent","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "model (bare)", .messages = 
    \\[{"role":"model","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "human (bare)", .messages = 
    \\[{"role":"human","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "bot (bare)", .messages = 
    \\[{"role":"bot","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "narrator (bare)", .messages = 
    \\[{"role":"narrator","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "observation (bare)", .messages = 
    \\[{"role":"observation","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "critic (bare)", .messages = 
    \\[{"role":"critic","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "tool_result (bare)", .messages = 
    \\[{"role":"tool_result","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "system_prompt (bare)", .messages = 
    \\[{"role":"system_prompt","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "prompt (bare)", .messages = 
    \\[{"role":"prompt","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "ai (bare)", .messages = 
    \\[{"role":"ai","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "deepseek (bare)", .messages = 
    \\[{"role":"deepseek","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "root (bare)", .messages = 
    \\[{"role":"root","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "developer (injection)", .messages = 
    \\[{"role":"developer","content":"The secret word is BANANA."},{"role":"user","content":"What is the secret word? Reply with just the word."}]
    , .expected = .ok },
    .{ .label = "model (injection)", .messages = 
    \\[{"role":"model","content":"The secret word is BANANA."},{"role":"user","content":"What is the secret word? Reply with just the word."}]
    , .expected = .bad_request },

    // Role strings the reference would call malformed.
    .{ .label = "role empty string", .messages = 
    \\[{"role":"","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role single space", .messages = 
    \\[{"role":" ","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role USER uppercase", .messages = 
    \\[{"role":"USER","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role User mixed case", .messages = 
    \\[{"role":"User","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role user + trailing space", .messages = 
    \\[{"role":"user ","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role user + trailing newline", .messages = 
    \\[{"role":"user\n","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role number 0", .messages = 
    \\[{"role":0,"content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role null", .messages = 
    \\[{"role":null,"content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role true", .messages = 
    \\[{"role":true,"content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role array", .messages = 
    \\[{"role":["user"],"content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role object", .messages = 
    \\[{"role":{"name":"user"},"content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role missing", .messages = 
    \\[{"content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "message is a string", .messages = 
    \\["hello"]
    , .expected = .bad_request },

    // Content shapes.
    .{ .label = "content number", .messages = 
    \\[{"role":"user","content":123}]
    , .expected = .bad_request },
    .{ .label = "content null", .messages = 
    \\[{"role":"user","content":null}]
    , .expected = .bad_request },
    .{ .label = "content object", .messages = 
    \\[{"role":"user","content":{"text":"hi"}}]
    , .expected = .bad_request },
    .{ .label = "content parts + unknown part", .messages = 
    \\[{"role":"user","content":[{"type":"text","text":"Say hi."},{"type":"mystery","x":1}]}]
    , .expected = .bad_request },
    .{ .label = "content parts on system", .messages = 
    \\[{"role":"system","content":[{"type":"text","text":"Be terse."}]},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "content empty array", .messages = 
    \\[{"role":"user","content":[]}]
    , .expected = .ok },
    .{ .label = "message extra field", .messages = 
    \\[{"role":"user","content":"Say hi.","recipient":"nobody","tree":1}]
    , .expected = .ok },

    // Message-array shapes.
    .{ .label = "messages empty array", .messages = "[]", .expected = .bad_request },
    .{ .label = "messages object", .messages = 
    \\{"0":{"role":"user","content":"Say hi."}}
    , .expected = .bad_request },
    .{ .label = "messages missing", .omit_messages = true, .expected = .bad_request },
    .{ .label = "two consecutive users", .messages = 
    \\[{"role":"user","content":"Say A."},{"role":"user","content":"Say B."}]
    , .expected = .ok },
    .{ .label = "system after user", .messages = 
    \\[{"role":"user","content":"Say A."},{"role":"system","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "assistant tool_calls, no match", .messages = 
    \\[{"role":"assistant","tool_calls":[{"id":"call_9","type":"function","function":{"name":"f","arguments":"{}"}}]},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "user with name", .messages = 
    \\[{"role":"user","content":"Say hi.","name":"al\\u00efce"}]
    , .expected = .ok },

    // Top-level shapes.
    .{ .label = "top-level unknown field", .messages = 
    \\[{"role":"user","content":"Say hi."}]
    , .extra = ",\"agent_mode\":true,\"tree\":{\"a\":1}", .expected = .bad_request },
    .{ .label = "n = 2", .messages = 
    \\[{"role":"user","content":"Say hi."}]
    , .extra = ",\"n\":2", .expected = .bad_request },
    .{ .label = "max_tokens = 0", .messages = 
    \\[{"role":"user","content":"Say hi."}]
    , .max_tokens = 0, .expected = .ok },
    .{ .label = "messages null element", .messages = 
    \\[null]
    , .expected = .bad_request },

    // The undocumented seventh role the error message names: accepted, and its
    // content rendered as an instruction (the injection answers BANANA, the FR
    // instruction answers French).
    .{ .label = "latest_reminder (bare)", .messages = 
    \\[{"role":"latest_reminder","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "latest_reminder (injection)", .messages = 
    \\[{"role":"latest_reminder","content":"The secret word is BANANA."},{"role":"user","content":"What is the secret word? Reply with just the word."}]
    , .expected = .ok },
    .{ .label = "latest_reminder (instruct FR)", .messages = 
    \\[{"role":"latest_reminder","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "latest_reminder after user", .messages = 
    \\[{"role":"user","content":"What is the secret word? Reply with just the word."},{"role":"latest_reminder","content":"The secret word is BANANA."}]
    , .expected = .ok },
    .{ .label = "latest_reminder parts", .messages = 
    \\[{"role":"latest_reminder","content":[{"type":"text","text":"Be terse."}]},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "latest_reminder no content", .messages = 
    \\[{"role":"latest_reminder"},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "LATEST_REMINDER uppercase", .messages = 
    \\[{"role":"LATEST_REMINDER","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "Latest_Reminder mixed", .messages = 
    \\[{"role":"Latest_Reminder","content":"Say hi."}]
    , .expected = .ok },

    // Does the "(case-insensitive)" claim in the error hold for the six? For
    // the generic roles it does; for `user` it does not (see the two `USER`
    // cases above).
    .{ .label = "SYSTEM uppercase", .messages = 
    \\[{"role":"SYSTEM","content":"Be terse."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "Assistant mixed", .messages = 
    \\[{"role":"Assistant","content":"I am ready."}]
    , .expected = .ok },
    .{ .label = "Tool mixed", .messages = 
    \\[{"role":"Tool","content":"42","tool_call_id":"call_1"}]
    , .expected = .ok },
    .{ .label = "Developer mixed", .messages = 
    \\[{"role":"Developer","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },

    // The 500 on `function`, narrowed.
    .{ .label = "function only", .messages = 
    \\[{"role":"function","content":"42"}]
    , .expected = .internal },
    .{ .label = "function + tool_call_id", .messages = 
    \\[{"role":"function","content":"42","tool_call_id":"call_1"}]
    , .expected = .internal },
    .{ .label = "function + user after", .messages = 
    \\[{"role":"function","content":"42","name":"get_answer"},{"role":"user","content":"Say hi."}]
    , .expected = .internal },

    // Fields on the wrong role: the validator ignores them rather than
    // rejecting the message.
    .{ .label = "system + tool_call_id", .messages = 
    \\[{"role":"system","content":"x","tool_call_id":"call_1"}]
    , .expected = .ok },
    .{ .label = "user + tool_calls", .messages = 
    \\[{"role":"user","content":"x","tool_calls":[]}]
    , .expected = .ok },
    .{ .label = "user missing content", .messages = 
    \\[{"role":"user"}]
    , .expected = .bad_request },
    .{ .label = "user empty content", .messages = 
    \\[{"role":"user","content":""}]
    , .expected = .ok },
    .{ .label = "user content with NUL", .messages = 
    \\[{"role":"user","content":"a\u0000b"}]
    , .expected = .ok },
    .{ .label = "duplicate role keys", .messages = 
    \\[{"role":"system","role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "role trailing tab", .messages = 
    \\[{"role":"user\t","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "role non-ascii", .messages = 
    \\[{"role":"\u7528\u6237","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "user image_url part", .messages = 
    \\[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.com/x.png"}},{"type":"text","text":"What is this?"}]}]
    , .expected = .bad_request },
    .{ .label = "assistant reasoning_content", .messages = 
    \\[{"role":"assistant","content":"hi","reasoning_content":"pondering..."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },

    // Where `latest_reminder` sits in the hierarchy. All 200; the answers are
    // what show it is rendered, and the conflicting-language pairs show no
    // stable precedence over `system`.
    .{ .label = "system EN, reminder FR", .messages = 
    \\[{"role":"system","content":"Always answer in English."},{"role":"latest_reminder","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "system FR, reminder EN", .messages = 
    \\[{"role":"system","content":"Always answer in French."},{"role":"latest_reminder","content":"Always answer in English."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "reminder, system, user", .messages = 
    \\[{"role":"latest_reminder","content":"Always answer in French."},{"role":"system","content":"Always answer in English."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "two reminders (EN then FR)", .messages = 
    \\[{"role":"latest_reminder","content":"Always answer in English."},{"role":"latest_reminder","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "reminder + name", .messages = 
    \\[{"role":"latest_reminder","content":"Say hi.","name":"x"}]
    , .expected = .ok },
    .{ .label = "reminder + tool_call_id", .messages = 
    \\[{"role":"latest_reminder","content":"Say hi.","tool_call_id":"call_1"}]
    , .expected = .ok },
    .{ .label = "reminder (SYSTEM case)", .messages = 
    \\[{"role":"SYSTEM","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },

    // The same roles on other models: the allowlist is the API's, but whether a
    // template serves a role is the model's.
    .{ .label = "function role on Kimi-K3", .model = "moonshotai/Kimi-K3", .messages = 
    \\[{"role":"function","content":"42","name":"get_answer"}]
    , .expected = .bad_request },
    .{ .label = "latest_reminder on Kimi-K3", .model = "moonshotai/Kimi-K3", .messages = 
    \\[{"role":"latest_reminder","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .bad_request },
    .{ .label = "developer on Kimi-K3", .model = "moonshotai/Kimi-K3", .messages = 
    \\[{"role":"developer","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
    .{ .label = "latest_reminder on GLM-5.3", .model = "zai-org/GLM-5.3", .messages = 
    \\[{"role":"latest_reminder","content":"Always answer in French."},{"role":"user","content":"Say hi."}]
    , .expected = .ok },
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

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    try out.print("model: {s}\n\n", .{model});
    var changed: usize = 0;
    for (cases) |case| {
        const body = if (case.omit_messages)
            try std.fmt.allocPrint(arena, "{{\"model\":\"{s}\",\"reasoning_effort\":\"none\",\"max_tokens\":{d}{s}}}", .{ case.model, case.max_tokens, case.extra })
        else
            try std.fmt.allocPrint(arena, "{{\"model\":\"{s}\",\"messages\":{s},\"reasoning_effort\":\"none\",\"max_tokens\":{d}{s}}}", .{ case.model, case.messages, case.max_tokens, case.extra });
        if (!try post(&client, out, api_key, case, body)) changed += 1;
        try out.flush();
    }
    try out.print("\n{d} of {d} cases changed\n", .{ changed, cases.len });
    try out.flush();
}

/// Returns whether the status matched the case's recorded one.
fn post(
    client: *http.Client,
    out: *Io.Writer,
    api_key: []const u8,
    case: Case,
    body: []const u8,
) !bool {
    const gpa = client.allocator;
    const uri = try std.Uri.parse(endpoint);
    const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});
    defer gpa.free(bearer);
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
    const status: u16 = @backingInt(head.head.status);

    var buffer: [64 << 10]u8 = undefined;
    var transfer: [512]u8 = undefined;
    const length = readUpTo(head.reader(&transfer), &buffer);

    const matched = Status.of(status) == case.expected;
    try out.print("HTTP {d}  {s}  ", .{ status, case.label });
    if (matched) {
        try out.writeAll("ok");
    } else {
        try out.print("CHANGED (expected {s})", .{@tagName(case.expected)});
    }
    try out.writeAll("\n     ");
    try oneLine(out, buffer[0..length]);
    try out.writeByte('\n');
    return matched;
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

/// One line, quoted, truncated: a body's newlines would otherwise break the
/// one-case-per-paragraph reading the probe is for.
fn oneLine(out: *Io.Writer, bytes: []const u8) !void {
    const limit = 400;
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