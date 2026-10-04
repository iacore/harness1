//! Judges one answer against a rubric and prints a boolean verdict.
//!
//! This is the outside check. The program that produced an answer is not the
//! one that says whether the answer is any good: the judgement is a separate
//! process making its own request, and it comes back as a tool call whose
//! arguments the API's strict mode has shaped.
//!
//! Design decisions:
//!
//!   * The verdict is forced, not requested. `tool_choice` names the `verdict`
//!     function, so a turn that answers in prose instead of calling it is a
//!     failure to judge rather than a judgement that passed. That is the whole
//!     difference between a judge and a commenter.
//!   * Forced tool calling and thinking mode are mutually exclusive by the
//!     API's own documentation. The judge therefore runs with thinking off.
//!     `--thinking` sends the request anyway, which is how that restriction is
//!     observed in this checkout rather than taken on faith.
//!   * Failure to obtain a verdict is an exit status, not `false`. A judge
//!     that answers "does not pass" when it did not run cannot be told from one
//!     that ran and disapproved, and every pass rate computed from it would be
//!     wrong in the same direction.
//!
//! Usage:
//!
//!   zhengjian_judger <request.json> [--beta] [--thinking]
//!
//! The request file is `{"question": ..., "answer": ..., "rubric": ...}` and
//! the verdict is written to stdout as `{"pass": ..., "why": ...}`.
//!
//! Exit status: 0 verdict obtained, 1 the request failed, 2 no well-formed
//! tool call came back.

const std = @import("std");
const Io = std.Io;
const harness1 = @import("harness1");
const deepseek = harness1.deepseek;
const keys = harness1.keys;
const chat = deepseek.chat;

/// The name the forced tool is declared and chosen under.
const tool_name = "verdict";

/// `rubric` says what a passing answer must do, and is the only thing the
/// verdict is measured against.
pub const Request = struct {
    question: []const u8,
    answer: []const u8,
    rubric: []const u8,
};

const Verdict = struct {
    pass: bool,
    why: []const u8,
};

/// The judge's standing instruction. It is written to make a doubtful verdict
/// a failing one: the caller wants to know which prompting technique holds up,
/// and a judge that waves an answer through on a charitable reading makes every
/// technique look equally good.
const instruction =
    \\You judge one answer against a rubric.
    \\
    \\Rules:
    \\- The rubric states what a passing answer must do. Judge only whether the
    \\  answer does it. Not style, not length, not tone, not effort.
    \\- Judge what the answer says, not what it could be read to mean.
    \\- If the rubric names a mistake, an answer that makes that mistake does
    \\  not pass, however much else it gets right.
    \\- If you cannot tell whether the answer meets the rubric, it does not
    \\  pass. Name in `why` what was missing.
    \\- Base the verdict only on the question and answer given to you. Do not
    \\  supply facts of your own, and do not credit the answer for a fact it
    \\  did not state.
    \\- `why` is one sentence naming the single thing that decided it.
    \\
;

/// The arguments of the forced tool, written as a strict schema so the server
/// rejects a call the shape of which this program cannot read. Strict mode
/// requires every property, which is why the type has no optional fields to
/// leave out.
const parameters = chat.StrictSchema{
    .type = .object,
    .properties = &.{
        .{
            .name = "pass",
            .schema = .{
                .type = .boolean,
                .description = "Whether the answer does what the rubric requires.",
            },
        },
        .{
            .name = "why",
            .schema = .{
                .type = .string,
                .description = "The single fact that decided the verdict, in one sentence.",
            },
        },
    },
};

const tools = [_]chat.Tool{.{
    .function = .{
        .name = tool_name,
        .description = "Return the verdict on the answer.",
        .parameters = .{ .strict = parameters },
    },
}};

/// How the run ended. Distinct values because a caller has to be able to tell a
/// verdict of "no" from no verdict at all.
const Exit = struct {
    const verdict: u8 = 0;
    const request_failed: u8 = 1;
    const no_tool_call: u8 = 2;
    const bad_usage: u8 = 64;
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    var path: ?[]const u8 = null;
    var beta = false;
    var thinking = false;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--beta")) {
            beta = true;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            thinking = true;
        } else if (arg.len != 0 and arg[0] == '-') {
            try out.print("unknown option: {s}\n", .{arg});
            try out.flush();
            std.process.exit(Exit.bad_usage);
        } else if (path == null) {
            path = arg;
        }
    }
    const request_path = path orelse {
        try out.writeAll("usage: zhengjian_judger <request.json> [--beta] [--thinking]\n");
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };

    const raw = Io.Dir.cwd().readFileAlloc(io, request_path, gpa, .limited(4 << 20)) catch |err| {
        try out.print("cannot read {s}: {s}\n", .{ request_path, @errorName(err) });
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };
    defer gpa.free(raw);

    var parsed = std.json.parseFromSlice(Request, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try out.print("{s} is not a judge request: {s}\n", .{ request_path, @errorName(err) });
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };
    defer parsed.deinit();
    const request = parsed.value;

    const api_key = try keys.apiKey(arena, io, init.environ_map, keys.Provider.deepseek) orelse {
        try out.writeAll("no DeepSeek key: set DEEPSEEK_API_KEY, or sign in to the `deepseek` provider of omp\n");
        try out.flush();
        std.process.exit(Exit.request_failed);
    };

    var client = try deepseek.Client.init(gpa, io, api_key, .{ .beta = beta });
    defer client.deinit();

    // The judge sees the answer and the rubric; it never sees the prompt that
    // produced the answer, so it cannot be swayed by how the question was put.
    const user = try std.fmt.allocPrint(arena, "Question:\n{s}\n\nAnswer:\n{s}\n\nRubric:\n{s}\n", .{
        request.question, request.answer, request.rubric,
    });

    const messages = [_]chat.Message{
        .{ .system = .{ .content = instruction } },
        .{ .user = .{ .content = deepseek.chat.text(user) } },
    };

    const result = try chat.send(&client, &.{
        .model = deepseek.Model.flash,
        .messages = &messages,
        .thinking = if (thinking) .enabled else .disabled,
        .tools = &tools,
        .tool_choice = .{ .function = tool_name },
        // No sampling: the judge is asked for a reading of a text, and the
        // same reading should come back twice.
        .temperature = 0,
    });

    var completion = switch (result) {
        .ok => |ok| ok,
        .err => |failure| {
            try out.writeAll("judge request failed: ");
            try failure.format(out);
            try out.writeByte('\n');
            try out.flush();
            std.process.exit(Exit.request_failed);
        },
    };
    defer completion.deinit();

    const message = completion.value.message();
    if (message.tool_calls.len == 0) {
        try out.print("no tool call: {s}\n", .{message.content orelse ""});
        try out.flush();
        std.process.exit(Exit.no_tool_call);
    }

    const arguments = message.tool_calls[0].function.arguments;
    var verdict = std.json.parseFromSlice(Verdict, arena, arguments, .{
        .ignore_unknown_fields = false,
    }) catch |err| {
        try out.print("unreadable tool arguments ({s}): {s}\n", .{ @errorName(err), arguments });
        try out.flush();
        std.process.exit(Exit.no_tool_call);
    };
    defer verdict.deinit();

    try out.print("{{\"pass\": {s}, \"why\": ", .{if (verdict.value.pass) "true" else "false"});
    try std.json.Stringify.value(verdict.value.why, .{}, out);
    try out.writeAll("}\n");
    try out.flush();
}
