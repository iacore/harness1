//! Probes how DeepSeek-on-LithosAI treats `system` versus `developer`.
//!
//! A scratch program like `lithos_probe`: it needs a key and a network, so it
//! is neither installed nor built by the default step.
//!
//!   zig build --build-file ./build.research.zig lithos_sysdev
//!
//! The discriminator is a codeword. One turn says `The secret codeword is
//! ALPHA.` in `system` or in `developer`; a later user turn asks for it. Which
//! codeword comes back says which turn the model read, and in which order,
//! when several are present. Each case runs `trials` times, because a single
//! answer cannot tell a stable rule from one sample.
//!
//! Findings belong in src/remote/lithos_models.md.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const lithos = run1.lithos;
const chat = lithos.chat;
const keys = run1.keys;
const debug = run1.debug;

const model = "deepseek-ai/DeepSeek-V4.1-Flash";
const trials = 3;

const alpha = "The secret codeword is ALPHA.";
const beta = "The secret codeword is BETA.";
const question = "What is the secret codeword? Reply with only the codeword.";
const hi = "Say hi.";

const Case = struct {
    label: []const u8,
    messages: []const chat.Message,
};

fn system(content: []const u8) chat.Message {
    return .{ .system = .{ .content = chat.text(content) } };
}
// The `developer` role is removed from `chat.Message` (src/remote/lithos.zig):
// the union is system, user, assistant, tool, latest_reminder. Every case below
// that builds one no longer compiles, so this file is kept as the record of
// what was probed, not as a program.
fn developer(content: []const u8) chat.Message {
    return .{ .developer = .{ .content = chat.text(content) } };
}
fn user(content: []const u8) chat.Message {
    return .{ .user = .{ .content = chat.text(content) } };
}

const sys_first = [_]chat.Message{ system(alpha), user(question) };
const dev_first = [_]chat.Message{ developer(alpha), user(question) };
const sys_then_dev = [_]chat.Message{ system(alpha), developer(beta), user(question) };
const dev_then_sys = [_]chat.Message{ developer(beta), system(alpha), user(question) };
const sys_later = [_]chat.Message{ user(hi), system(alpha), user(question) };
const dev_later = [_]chat.Message{ user(hi), developer(alpha), user(question) };
const sys_first_dev_later = [_]chat.Message{ system(alpha), user(hi), developer(beta), user(question) };
const dev_first_sys_later = [_]chat.Message{ developer(beta), user(hi), system(alpha), user(question) };
const sys_after_ask = [_]chat.Message{ user(question), system(alpha) };
const dev_after_ask = [_]chat.Message{ user(question), developer(alpha) };

const cases = [_]Case{
    .{ .label = "system first", .messages = &sys_first },
    .{ .label = "developer first", .messages = &dev_first },
    .{ .label = "system ALPHA, developer BETA (both first)", .messages = &sys_then_dev },
    .{ .label = "developer BETA, system ALPHA (both first)", .messages = &dev_then_sys },
    .{ .label = "system later (after a user turn)", .messages = &sys_later },
    .{ .label = "developer later (after a user turn)", .messages = &dev_later },
    .{ .label = "system first, developer later", .messages = &sys_first_dev_later },
    .{ .label = "developer first, system later", .messages = &dev_first_sys_later },
    .{ .label = "system after the question", .messages = &sys_after_ask },
    .{ .label = "developer after the question", .messages = &dev_after_ask },
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

    var client = try lithos.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    try out.print("model: {s}   trials: {d}\n\n", .{ model, trials });
    for (cases) |case| {
        try out.print("{s}\n", .{case.label});
        for (0..trials) |_| {
            try out.writeAll("  ");
            try ask(&client, out, case.messages);
        }
        try out.flush();
    }
}

fn ask(client: *lithos.Client, out: *Io.Writer, messages: []const chat.Message) !void {
    const result = try chat.send(client, &.{
        .model = model,
        .messages = messages,
        .reasoning_effort = .{ .named = .none },
        .max_tokens = 24,
    });
    switch (result) {
        .ok => |parsed| {
            defer parsed.deinit();
            const message = parsed.value.message();
            if (message.content) |content| {
                try oneLine(out, content);
            } else {
                try out.writeAll("(no content)");
            }
            try out.writeByte('\n');
        },
        .err => |failure| {
            try out.writeAll("refused: ");
            try failure.format(out);
            try out.writeByte('\n');
        },
    }
}

/// One line, trimmed and truncated: an answer with newlines would otherwise
/// rob the trial list of its shape.
fn oneLine(out: *Io.Writer, bytes: []const u8) !void {
    const text = std.mem.trim(u8, bytes, " \t\r\n");
    const limit = 80;
    for (text, 0..) |c, i| {
        if (i >= limit) {
            try out.writeAll(" ...");
            return;
        }
        try out.writeByte(if (c == '\n' or c == '\r') ' ' else c);
    }
}