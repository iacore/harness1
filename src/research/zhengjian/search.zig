//! Runs a corpus of questions under several prompting techniques and reports
//! which technique answered every one of them acceptably, every time.
//!
//! The corpus is the ground truth, the technique is the variable, and the
//! verdict comes from `zhengjian_judger` — a separate process making its own
//! request. Nothing here grades its own output.
//!
//! Deciding points:
//!
//!   * "Reliably" is the bar, not "usually". A technique that passes three
//!     trials of four cases and fails the fourth is reported as failing, and
//!     the counts stay visible so that a technique at 11/12 is not confused
//!     with one at 12/12.
//!   * A judgement that could not be obtained is counted apart from both
//!     outcomes. Folding it into "failed" would make an interrupted run look
//!     like a decisive one, and folding it into "passed" is worse.
//!   * Thinking is off for the answers by default. The search varies one thing
//!     — the prompt — and a chain of thought is a second variable; it is also
//!     the mode the judge runs in, which keeps the two halves comparable. Pass
//!     `--thinking` to see whether it changes the ranking.
//!
//! Usage:
//!
//!   zhengjian_search --corpus <corpus.json> --techniques <techniques.json>
//!                    [--judger <path>] [--trials N] [--out <results.json>]
//!                    [--work <dir>] [--thinking] [--verbose]
//!
//! Exit status: 0 every technique judged cleanly, 3 some judgement was not
//! obtained, 64 usage.

const std = @import("std");
const Io = std.Io;
const harness1 = @import("harness1");
const deepseek = harness1.deepseek;
const keys = harness1.keys;
const chat = deepseek.chat;

/// One question, and what an acceptable answer to it must do.
const Case = struct {
    id: []const u8,
    /// Where the expectation comes from, for the report.
    source: []const u8 = "",
    question: []const u8,
    /// What a passing answer must do, handed to the judge unmodified.
    rubric: []const u8,
};

const Corpus = struct { cases: []const Case };

/// One prompting technique: the system message the question is put under.
const Technique = struct {
    id: []const u8,
    system: []const u8 = "",
};

const Techniques = struct { techniques: []const Technique };

/// The judge's answer, as `zhengjian_judger` prints it.
const Verdict = struct {
    pass: bool,
    why: []const u8,
};

const Outcome = enum {
    passed,
    failed,
    /// The judgement never arrived. Kept apart: it is evidence about the
    /// harness, not about the technique.
    unjudged,
};

const Attempt = struct {
    technique: []const u8,
    case_id: []const u8,
    trial: usize,
    outcome: Outcome,
    answer: []const u8,
    why: []const u8,
};

const Tally = struct {
    passed: usize = 0,
    failed: usize = 0,
    unjudged: usize = 0,

    fn total(self: Tally) usize {
        return self.passed + self.failed + self.unjudged;
    }

    /// A technique is reliable when it was judged on every attempt and passed
    /// every one. An unjudged attempt is not a pass.
    fn reliable(self: Tally) bool {
        return self.total() != 0 and self.failed == 0 and self.unjudged == 0;
    }
};

const Exit = struct {
    const ok: u8 = 0;
    const unjudged: u8 = 3;
    const bad_usage: u8 = 64;
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);

    var corpus_path: ?[]const u8 = null;
    var techniques_path: ?[]const u8 = null;
    var judger_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var work_dir: []const u8 = "zig-out/zhengjian";
    var trials: usize = 3;
    var temperature: f64 = 0;
    var only: ?[]const u8 = null;
    var thinking = false;
    var verbose = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--corpus")) {
            i += 1;
            if (i == argv.len) return usage(out);
            corpus_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--techniques")) {
            i += 1;
            if (i == argv.len) return usage(out);
            techniques_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--judger")) {
            i += 1;
            if (i == argv.len) return usage(out);
            judger_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i == argv.len) return usage(out);
            out_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--work")) {
            i += 1;
            if (i == argv.len) return usage(out);
            work_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--trials")) {
            i += 1;
            if (i == argv.len) return usage(out);
            trials = std.fmt.parseInt(usize, argv[i], 10) catch return usage(out);
        } else if (std.mem.eql(u8, arg, "--temperature")) {
            i += 1;
            if (i == argv.len) return usage(out);
            temperature = std.fmt.parseFloat(f64, argv[i]) catch return usage(out);
        } else if (std.mem.eql(u8, arg, "--only")) {
            i += 1;
            if (i == argv.len) return usage(out);
            only = argv[i];
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            thinking = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else {
            return usage(out);
        }
    }

    const corpus_file = corpus_path orelse return usage(out);
    const techniques_file = techniques_path orelse return usage(out);
    // The corpus and the techniques are the caller's files; the judger is a
    // program, and without its path there is no verdict to be had.
    const judge_program = judger_path orelse {
        try out.writeAll("--judger is required: this program does not judge its own output\n");
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };
    if (trials == 0) {
        try out.writeAll("--trials must be at least 1\n");
        try out.flush();
        std.process.exit(Exit.bad_usage);
    }

    const corpus_raw = Io.Dir.cwd().readFileAlloc(io, corpus_file, gpa, .limited(4 << 20)) catch |err| {
        try out.print("cannot read {s}: {s}\n", .{ corpus_file, @errorName(err) });
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };
    defer gpa.free(corpus_raw);
    var corpus_parsed = std.json.parseFromSlice(Corpus, arena, corpus_raw, .{ .ignore_unknown_fields = true }) catch |err| {
        try out.print("{s} is not a corpus: {s}\n", .{ corpus_file, @errorName(err) });
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };
    defer corpus_parsed.deinit();

    const techniques_raw = Io.Dir.cwd().readFileAlloc(io, techniques_file, gpa, .limited(4 << 20)) catch |err| {
        try out.print("cannot read {s}: {s}\n", .{ techniques_file, @errorName(err) });
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };
    defer gpa.free(techniques_raw);
    var techniques_parsed = std.json.parseFromSlice(Techniques, arena, techniques_raw, .{ .ignore_unknown_fields = true }) catch |err| {
        try out.print("{s} is not a technique set: {s}\n", .{ techniques_file, @errorName(err) });
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };
    defer techniques_parsed.deinit();

    const cases = corpus_parsed.value.cases;
    const techniques = techniques_parsed.value.techniques;
    if (cases.len == 0 or techniques.len == 0) {
        try out.writeAll("the corpus and the technique set must both be non-empty\n");
        try out.flush();
        std.process.exit(Exit.bad_usage);
    }

    // The judge is handed its requests through files, one per judgement, kept
    // under `--work`. Writing them out rather than piping them is what makes a
    // single verdict reproducible by hand afterwards, which is the difference
    // between a result and an anecdote.
    Io.Dir.cwd().createDirPath(io, work_dir) catch |err| {
        try out.print("cannot create {s}: {s}\n", .{ work_dir, @errorName(err) });
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };

    const api_key = try keys.apiKey(arena, io, init.environ_map, keys.Provider.deepseek) orelse {
        try out.writeAll("no DeepSeek key: set DEEPSEEK_API_KEY, or sign in to the `deepseek` provider of omp\n");
        try out.flush();
        std.process.exit(Exit.bad_usage);
    };

    var client = try deepseek.Client.init(gpa, io, api_key, .{});
    defer client.deinit();

    var attempts: std.ArrayListUnmanaged(Attempt) = .empty;
    defer attempts.deinit(gpa);

    var tallies: std.ArrayListUnmanaged(Tally) = .empty;
    defer tallies.deinit(gpa);
    try tallies.appendNTimes(gpa, .{}, techniques.len);

    var request_buffer: [64 << 10]u8 = undefined;

    for (techniques, 0..) |technique, technique_index| {
        for (cases) |case| {
            // `--only` narrows the run to one case, so the case that separates
            // the techniques can be sampled harder than the rest without
            // paying for the ones they all pass.
            if (only) |id| {
                if (!std.mem.eql(u8, id, case.id)) continue;
            }
            for (0..trials) |trial| {
                const answer = try ask(&client, arena, technique, case, thinking, temperature);

                var why: []const u8 = "";
                const outcome: Outcome = outcome: {
                    const verdict = judge(
                        gpa,
                        io,
                        arena,
                        judge_program,
                        work_dir,
                        technique.id,
                        case,
                        trial,
                        answer,
                        &request_buffer,
                    ) catch |err| {
                        why = @errorName(err);
                        break :outcome .unjudged;
                    };
                    if (verdict) |v| {
                        why = v.why;
                        break :outcome if (v.pass) .passed else .failed;
                    }
                    why = "no verdict";
                    break :outcome .unjudged;
                };

                switch (outcome) {
                    .passed => tallies.items[technique_index].passed += 1,
                    .failed => tallies.items[technique_index].failed += 1,
                    .unjudged => tallies.items[technique_index].unjudged += 1,
                }

                try attempts.append(gpa, .{
                    .technique = technique.id,
                    .case_id = case.id,
                    .trial = trial,
                    .outcome = outcome,
                    .answer = answer,
                    .why = why,
                });

                if (verbose) {
                    try out.print("{s} / {s} / {d}: {s}\n", .{
                        technique.id,
                        case.id,
                        trial,
                        switch (outcome) {
                            .passed => "pass",
                            .failed => "FAIL",
                            .unjudged => "UNJUDGED",
                        },
                    });
                    if (outcome != .passed) try out.print("    rubric: {s}\n    answer: {s}\n    why:    {s}\n", .{ case.rubric, answer, why });
                    try out.flush();
                }
            }
        }
    }

    var width: usize = 9;
    for (techniques) |technique| width = @max(width, technique.id.len);

    // Padded by hand rather than with format widths: technique ids are the
    // caller's strings, and a name holding anything the format language reads
    // as a specifier would otherwise break the report.
    try out.writeByte('\n');
    try pad(out, "technique", width);
    try out.writeAll("  ");
    try rpad(out, "passed", 6);
    try out.writeAll("  ");
    try rpad(out, "failed", 6);
    try out.writeAll("  ");
    try rpad(out, "unjudged", 8);
    try out.writeAll("  reliable\n");
    var rule: usize = 0;
    while (rule < width + 30) : (rule += 1) try out.writeByte('-');
    try out.writeByte('\n');

    var unjudged_total: usize = 0;
    var number_buffer: [20]u8 = undefined;
    for (techniques, 0..) |technique, index| {
        const tally = tallies.items[index];
        unjudged_total += tally.unjudged;
        try pad(out, technique.id, width);
        try out.writeAll("  ");
        try rpad(out, try std.fmt.bufPrint(&number_buffer, "{d}", .{tally.passed}), 6);
        try out.writeAll("  ");
        try rpad(out, try std.fmt.bufPrint(&number_buffer, "{d}", .{tally.failed}), 6);
        try out.writeAll("  ");
        try rpad(out, try std.fmt.bufPrint(&number_buffer, "{d}", .{tally.unjudged}), 8);
        try out.writeAll("  ");
        try out.writeAll(if (tally.reliable()) "yes" else "no");
        try out.writeByte('\n');
    }
    try out.flush();

    if (out_path) |path| {
        var buffer: [8192]u8 = undefined;
        var file_writer = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            try out.print("cannot write {s}: {s}\n", .{ path, @errorName(err) });
            try out.flush();
            std.process.exit(Exit.bad_usage);
        };
        defer file_writer.close(io);
        var writer = file_writer.writer(io, &buffer);
        try std.json.Stringify.value(attempts.items, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    if (unjudged_total != 0) std.process.exit(Exit.unjudged);
}

/// Writes `s` left-aligned in a field of `width`.
fn pad(out: *Io.Writer, s: []const u8, width: usize) !void {
    try out.writeAll(s);
    var written = s.len;
    while (written < width) : (written += 1) try out.writeByte(' ');
}

/// Writes `s` right-aligned in a field of `width`.
fn rpad(out: *Io.Writer, s: []const u8, width: usize) !void {
    var written = s.len;
    while (written < width) : (written += 1) try out.writeByte(' ');
    try out.writeAll(s);
}

fn usage(out: *Io.Writer) void {
    out.writeAll(
        \\usage: zhengjian_search --corpus <corpus.json> --techniques <techniques.json>
        \\                        [--judger <path>] [--trials N] [--temperature F]
        \\                        [--only <case-id>] [--out <results.json>]
        \\                        [--work <dir>] [--thinking] [--verbose]
        \\
    ) catch {};
    out.flush() catch {};
    std.process.exit(Exit.bad_usage);
}

/// Puts the question to the model under the technique's system message and
/// returns the answer text. Thinking, when off, still returns the completion
/// itself; the answer is what the judge sees either way, never the chain of
/// thought.
fn ask(
    client: *deepseek.Client,
    allocator: std.mem.Allocator,
    technique: Technique,
    case: Case,
    thinking: bool,
    temperature: f64,
) ![]const u8 {
    // A technique with an empty system message is the baseline, and puts no
    // system turn in front of the question at all; sending an empty one would
    // make the baseline a technique rather than the absence of one.
    var messages: [2]chat.Message = undefined;
    var count: usize = 0;
    if (technique.system.len != 0) {
        messages[count] = .{ .system = .{ .content = technique.system } };
        count += 1;
    }
    messages[count] = .{ .user = .{ .content = deepseek.chat.text(case.question) } };
    count += 1;

    const result = try chat.send(client, &.{
        .model = deepseek.Model.flash,
        .messages = messages[0..count],
        .thinking = if (thinking) .enabled else .disabled,
        // Zero by default, which asks the same question the same way and makes
        // a repeated trial mostly a check that nothing changed. Raise it to
        // sample the technique rather than pin it: "reliably" means it holds
        // across the spread, and a spread of one measures nothing.
        .temperature = temperature,
    });

    var completion = switch (result) {
        .ok => |ok| ok,
        .err => |failure| {
            var buffer: [4096]u8 = undefined;
            var file = Io.File.stderr().writerStreaming(client.io, &buffer);
            const err_out = &file.interface;
            try err_out.writeAll("ask failed: ");
            try failure.format(err_out);
            try err_out.writeByte('\n');
            try err_out.flush();
            return error.AskFailed;
        },
    };
    defer completion.deinit();

    const content = completion.value.message().content orelse "";
    return try allocator.dupe(u8, content);
}

/// Asks `zhengjian_judger` for a verdict, returning null when it ran but
/// returned no verdict, and an error when it could not be run at all.
fn judge(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    judger_path: []const u8,
    work_dir: []const u8,
    technique_id: []const u8,
    case: Case,
    trial: usize,
    answer: []const u8,
    request_buffer: []u8,
) !?Verdict {
    const request = .{
        .question = case.question,
        .answer = answer,
        .rubric = case.rubric,
    };
    var fixed = Io.Writer.fixed(request_buffer);
    try std.json.Stringify.value(request, .{}, &fixed);

    // The trial is in the name because it is the thing that differs between
    // two requests for one technique and case: without it each judgement
    // overwrites the last, and only the final trial of a run can be re-judged
    // by hand afterwards.
    const request_path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}-{d}.json", .{ work_dir, technique_id, case.id, trial });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = request_path, .data = fixed.buffered(), .flags = .{} });

    const run = try std.process.run(gpa, io, .{
        .argv = &.{ judger_path, request_path, "--beta" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);

    if (!run.term.success()) return null;

    var parsed = std.json.parseFromSlice(Verdict, arena, std.mem.trim(u8, run.stdout, " \t\r\n"), .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    // The verdict borrows the parse, so the string is copied out before the
    // parse is freed.
    return .{ .pass = parsed.value.pass, .why = try arena.dupe(u8, parsed.value.why) };
}
