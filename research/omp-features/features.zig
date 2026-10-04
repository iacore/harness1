//! Attributes every part of every omp session transcript to a named feature and
//! reports coverage.
//!
//! A "part" is one record or one structural element inside a record: a
//! top-level record, a message content block, a tool invocation, an injected
//! context kind, a mode, a session-lifecycle value, a tool operation. Each part
//! resolves to a feature name. A value the harness vocabulary does not contain
//! — a new tool, injection kind, mode, or enum member — prints as UNKNOWN and
//! leaves coverage below 100%, so the gap fails loudly instead of being
//! bucketed under a catch-all. That run is how the tables in
//! src/omp_features.zig stay complete: an unknown here is a feature to add.
//!
//! Run from the repository root:
//!   zig build --build-file ./build.research.zig omp_features
//!   zig build --build-file ./build.research.zig omp_features -- <sessions-root> --features
//!
//! Default root: $HOME/.omp/agent/sessions.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const Allocator = std.mem.Allocator;
const omp = @import("harness1").omp_features;

fn in(values: []const []const u8, s: []const u8) bool {
    for (values) |t| if (std.mem.eql(u8, t, s)) return true;
    return false;
}

// ── Classifier ──────────────────────────────────────────────────────────────

const Analyzer = struct {
    gpa: Allocator,
    arena: Allocator,
    known: std.StringHashMap(u64),
    unknown: std.StringHashMap(u64),
    parts: u64 = 0,
    lines: u64 = 0,
    skipped: u64 = 0,

    fn init(gpa: Allocator, arena: Allocator) Analyzer {
        return .{
            .gpa = gpa,
            .arena = arena,
            .known = std.StringHashMap(u64).init(gpa),
            .unknown = std.StringHashMap(u64).init(gpa),
        };
    }

    fn deinit(self: *Analyzer) void {
        var it = self.known.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.known.deinit();
        var iu = self.unknown.iterator();
        while (iu.next()) |e| self.gpa.free(e.key_ptr.*);
        self.unknown.deinit();
    }

    fn emit(self: *Analyzer, is_known: bool, comptime fmt: []const u8, args: anytype) !void {
        const key = try std.fmt.allocPrint(self.arena, fmt, args);
        const map = if (is_known) &self.known else &self.unknown;
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, key);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        self.parts += 1;
    }

    /// Records a value that must appear in the vocabulary for `kind`; unknown
    /// values fail coverage.
    fn value(self: *Analyzer, prefix: []const u8, kind: omp.Kind, v: []const u8) !void {
        if (in(omp.table(kind), v)) {
            try self.emit(true, "{s}.{s}", .{ prefix, v });
        } else {
            try self.emit(false, "UNKNOWN.{s}.{s}", .{ prefix, v });
        }
    }

    /// Records a tool operation value, which is known only when the tool
    /// models that operation and the value is one of its names.
    fn opValue(self: *Analyzer, prefix: []const u8, tool: []const u8, key: []const u8, v: []const u8) !void {
        const values = omp.operationValues(tool, key) orelse &.{};
        if (in(values, v)) {
            try self.emit(true, "{s}.{s}", .{ prefix, v });
        } else {
            try self.emit(false, "UNKNOWN.{s}.{s}", .{ prefix, v });
        }
    }

    fn classify(self: *Analyzer, obj: json.ObjectMap) !void {
        const ty = strOf(obj, "type") orelse return self.emit(false, "UNKNOWN.record.<no type>", .{});
        if (std.mem.eql(u8, ty, "message")) return self.message(obj);
        if (std.mem.eql(u8, ty, "custom")) return self.custom(obj);
        if (std.mem.eql(u8, ty, "custom_message")) {
            const ct = strOf(obj, "customType") orelse return self.emit(false, "UNKNOWN.custom_message.<no customType>", .{});
            return self.value("custom_message", .custom_message, ct);
        }
        if (std.mem.eql(u8, ty, "mode_change")) {
            const m = strOf(obj, "mode") orelse return self.emit(false, "UNKNOWN.mode.<no mode>", .{});
            return self.value("mode", .mode, m);
        }
        if (std.mem.eql(u8, ty, "thinking_level_change")) return self.thinkingLevel(obj);
        if (std.mem.eql(u8, ty, "model_change")) return self.modelChange(obj);
        if (std.mem.eql(u8, ty, "service_tier_change")) return self.emit(true, "service_tier", .{});
        if (std.mem.eql(u8, ty, "credential_pin")) {
            const p = strOf(obj, "provider") orelse return self.emit(false, "UNKNOWN.credential_pin.<no provider>", .{});
            return self.value("credential_pin", .credential_provider, p);
        }
        if (std.mem.eql(u8, ty, "ttsr_injection")) return self.ttsr(obj);
        if (std.mem.eql(u8, ty, "compaction")) return self.compaction(obj);
        if (std.mem.eql(u8, ty, "session")) return self.session(obj);
        if (std.mem.eql(u8, ty, "session_init")) return self.sessionInit(obj);
        if (std.mem.eql(u8, ty, "title")) {
            try self.emit(true, "title", .{});
            if (strOf(obj, "source")) |s| try self.value("title.source", .title_source, s);
            return;
        }
        if (std.mem.eql(u8, ty, "title_change")) {
            try self.emit(true, "title_change", .{});
            if (strOf(obj, "source")) |s| try self.value("title_change.source", .title_source, s);
            if (strOf(obj, "trigger")) |t| try self.value("title_change.trigger", .title_change_trigger, t);
            return;
        }
        if (std.mem.eql(u8, ty, "model_usage")) {
            const p = strOf(obj, "purpose") orelse return self.emit(false, "UNKNOWN.model_usage.<no purpose>", .{});
            try self.value("model_usage", .model_usage_purpose, p);
            if (strOf(obj, "api")) |a| try self.value("model_usage.api", .model_usage_api, a);
            if (strOf(obj, "provider")) |pr| try self.value("model_usage.provider", .provider, pr);
            return;
        }
        if (in(omp.table(.record_type), ty)) return self.emit(true, "record.{s}", .{ty});
        try self.emit(false, "UNKNOWN.record-type.{s}", .{ty});
    }

    fn message(self: *Analyzer, obj: json.ObjectMap) !void {
        const m = objOf(obj, "message") orelse return self.emit(false, "UNKNOWN.message.<no body>", .{});
        const role = strOf(m, "role") orelse return self.emit(false, "UNKNOWN.message.<no role>", .{});
        if (!in(omp.table(.role), role)) {
            try self.emit(false, "UNKNOWN.role.{s}", .{role});
        } else {
            try self.emit(true, "message.{s}", .{role});
        }
        if (m.get("content")) |c| {
            if (c == .array) for (c.array.items) |blk| try self.block(blk);
        }
        if (std.mem.eql(u8, role, "assistant")) return self.assistant(m);
        if (std.mem.eql(u8, role, "toolResult")) return self.toolResult(m);
        if (std.mem.eql(u8, role, "user")) return self.userMessage(m);
        if (std.mem.eql(u8, role, "developer")) {
            if (boolOf(m, "synthetic") orelse false) try self.emit(true, "developer.synthetic", .{});
        }
    }

    fn block(self: *Analyzer, blk: json.Value) !void {
        if (blk != .object) return self.emit(false, "UNKNOWN.block.<non-object>", .{});
        const b = blk.object;
        const kind = strOf(b, "type") orelse return self.emit(false, "UNKNOWN.block.<no type>", .{});
        if (std.mem.eql(u8, kind, "toolCall")) {
            const name = strOf(b, "name") orelse return self.emit(false, "UNKNOWN.tool_call.<no name>", .{});
            return self.value("tool_call", .tool, name);
        }
        try self.value("block", .block_kind, kind);
    }

    fn assistant(self: *Analyzer, m: json.ObjectMap) !void {
        if (present(m, "usage")) try self.emit(true, "assistant.usage", .{});
        if (present(m, "contextSnapshot")) try self.emit(true, "assistant.context_snapshot", .{});
        if (present(m, "stopDetails")) try self.emit(true, "assistant.stop_details", .{});
        if (present(m, "errorMessage")) try self.emit(true, "assistant.error", .{});
        if (present(m, "retryRecovery")) try self.emit(true, "assistant.retry_recovery", .{});
        if (present(m, "credentialId")) try self.emit(true, "assistant.credential", .{});
        if (present(m, "providerPayload")) try self.emit(true, "assistant.provider_payload", .{});
        if (present(m, "upstreamModel")) try self.emit(true, "assistant.upstream_model", .{});
        if (strOf(m, "api")) |a| try self.value("assistant.api", .api, a);
        if (strOf(m, "provider")) |p| try self.value("assistant.provider", .provider, p);
        if (strOf(m, "stopReason")) |s| try self.value("assistant.stop_reason", .stop_reason, s);
    }

    fn toolResult(self: *Analyzer, m: json.ObjectMap) !void {
        const name = strOf(m, "toolName") orelse "<no toolName>";
        try self.value("tool_result", .tool, name);
        if (objOf(m, "details")) |d| {
            for (omp.operation_keys) |k| {
                const v = strOf(d, k) orelse continue;
                const key = try std.fmt.allocPrint(self.arena, "tool_op.{s}.{s}", .{ name, k });
                defer self.arena.free(key);
                try self.opValue(key, name, k, v);
            }
        }
        if (boolOf(m, "useless") orelse false) try self.emit(true, "tool_result.useless", .{});
        if (present(m, "prunedAt")) try self.emit(true, "tool_result.pruned", .{});
        if (boolOf(m, "isError") orelse false) try self.emit(true, "tool_result.error", .{});
    }

    fn userMessage(self: *Analyzer, m: json.ObjectMap) !void {
        if (strOf(m, "attribution")) |a| try self.value("user.attribution", .user_attribution, a);
        if (boolOf(m, "synthetic") orelse false) try self.emit(true, "user.synthetic", .{});
        if (boolOf(m, "steering") orelse false) try self.emit(true, "user.steering", .{});
    }

    fn custom(self: *Analyzer, obj: json.ObjectMap) !void {
        const ct = strOf(obj, "customType") orelse return self.emit(false, "UNKNOWN.custom.<no customType>", .{});
        try self.value("custom", .custom, ct);
        const d = objOf(obj, "data") orelse return;
        if (std.mem.eql(u8, ct, "tool_execution_start")) {
            const name = strOf(d, "toolName") orelse return;
            try self.value("tool_exec", .tool, name);
            if (present(d, "intent")) try self.emit(true, "tool_exec.intent", .{});
            if (present(d, "args")) try self.emit(true, "tool_exec.args", .{});
        } else if (std.mem.eql(u8, ct, "session_exit")) {
            if (strOf(d, "kind")) |k| try self.value("session_exit", .session_exit_kind, k);
            if (strOf(d, "reason")) |r| try self.value("session_exit.reason", .session_exit_reason, r);
            if (present(d, "pendingToolCalls")) try self.emit(true, "session_exit.pending_tools", .{});
        } else if (std.mem.eql(u8, ct, "vibe-session-lifecycle")) {
            if (strOf(d, "action")) |a| try self.value("vibe.action", .vibe_action, a);
        } else if (std.mem.eql(u8, ct, "todo_hud_state")) {
            if (strOf(d, "visibility")) |v| try self.value("todo_hud.visibility", .hud_visibility, v);
        }
    }

    fn thinkingLevel(self: *Analyzer, obj: json.ObjectMap) !void {
        if (strOf(obj, "thinkingLevel")) |l| {
            try self.value("thinking_level", .thinking_level, l);
        } else {
            try self.emit(true, "thinking_level.unset", .{});
        }
        if (strOf(obj, "configured")) |c| try self.value("thinking_level.configured", .configured_level, c);
    }

    fn modelChange(self: *Analyzer, obj: json.ObjectMap) !void {
        try self.emit(true, "model_change", .{});
        if (strOf(obj, "role")) |r| try self.value("model_change.role", .model_change_role, r);
        if (boolOf(obj, "resolvedModelIsFallback") orelse false) try self.emit(true, "model_change.fallback", .{});
    }

    fn ttsr(self: *Analyzer, obj: json.ObjectMap) !void {
        try self.emit(true, "ttsr_injection", .{});
        const v = obj.get("injectedRules") orelse return;
        if (v != .array) return;
        for (v.array.items) |r| {
            if (r != .string) continue;
            try self.value("ttsr_rule", .ttsr_rule, r.string);
        }
    }

    fn compaction(self: *Analyzer, obj: json.ObjectMap) !void {
        const method = strOf(obj, "method") orelse "default";
        try self.value("compaction", .compaction_method, method);
        if (boolOf(obj, "fromExtension") orelse false) try self.emit(true, "compaction.from_extension", .{});
        if (present(obj, "preserveData")) try self.emit(true, "compaction.preserve_data", .{});
    }

    fn session(self: *Analyzer, obj: json.ObjectMap) !void {
        try self.emit(true, "session", .{});
        if (strOf(obj, "titleSource")) |s| try self.value("session.title_source", .title_source, s);
        if (present(obj, "parentSession")) try self.emit(true, "session.parent", .{});
        if (present(obj, "previousSessionFiles")) try self.emit(true, "session.previous_files", .{});
        if (present(obj, "providerPromptCacheKey")) try self.emit(true, "session.prompt_cache_key", .{});
    }

    fn sessionInit(self: *Analyzer, obj: json.ObjectMap) !void {
        try self.emit(true, "session_init", .{});
        if (strOf(obj, "agent")) |a| try self.value("session_init.agent", .agent, a);
        if (boolOf(obj, "readOnly") orelse false) try self.emit(true, "session_init.read_only", .{});
        if (strOf(obj, "modelRole")) |r| try self.value("session_init.model_role", .model_role, r);
        if (present(obj, "readSummarize")) try self.emit(true, "session_init.read_summarize", .{});
        if (present(obj, "outputSchema")) try self.emit(true, "session_init.output_schema", .{});
        if (strOf(obj, "outputSchemaMode")) |m| try self.value("session_init.output_schema_mode", .output_schema_mode, m);
        if (present(obj, "spawns")) try self.emit(true, "session_init.spawns", .{});
    }
};

// ── JSON helpers ────────────────────────────────────────────────────────────

fn strOf(obj: json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn objOf(obj: json.ObjectMap, name: []const u8) ?json.ObjectMap {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn boolOf(obj: json.ObjectMap, name: []const u8) ?bool {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn present(obj: json.ObjectMap, name: []const u8) bool {
    const v = obj.get(name) orelse return false;
    return switch (v) {
        .null => false,
        else => true,
    };
}

// ── Driver ──────────────────────────────────────────────────────────────────

const Counted = struct { key: []const u8, count: u64 };

fn byCountDesc(_: void, a: Counted, b: Counted) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.key, b.key);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena_state = init.arena;
    const arena = arena_state.allocator();

    var stdout_buffer: [1 << 16]u8 = undefined;
    var stdout_file = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_file.interface;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    var root: []const u8 = "";
    var verbose = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--features")) {
            verbose = true;
        } else if (root.len == 0) {
            root = argv[i];
        }
    }
    if (root.len == 0) {
        const home = init.environ_map.get("HOME") orelse {
            try out.writeAll("HOME is unset; pass the sessions root as an argument\n");
            try out.flush();
            return error.NoSessionsRoot;
        };
        root = try std.fs.path.join(arena, &.{ home, ".omp", "agent", "sessions" });
    }

    const dir = if (std.fs.path.isAbsolute(root))
        try Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var an = Analyzer.init(gpa, arena);
    defer an.deinit();

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var files: u64 = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        files += 1;

        const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(1 << 31));
        defer gpa.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            _ = arena_state.reset(.retain_capacity);
            const parsed = json.parseFromSlice(json.Value, arena, line, .{}) catch {
                an.skipped += 1;
                continue;
            };
            an.lines += 1;
            const root_value = parsed.value;
            if (root_value != .object) {
                try an.emit(false, "UNKNOWN.record.<non-object>", .{});
                continue;
            }
            try an.classify(root_value.object);
        }
    }

    const counted = an.parts;
    var unknown_total: u64 = 0;
    var iu = an.unknown.iterator();
    while (iu.next()) |e| unknown_total += e.value_ptr.*;

    const known_total = if (counted >= unknown_total) counted - unknown_total else 0;
    const coverage: f64 = if (counted == 0) 100.0 else @as(f64, @floatFromInt(known_total)) / @as(f64, @floatFromInt(counted)) * 100.0;

    try out.print("files:   {d}\n", .{files});
    try out.print("records: {d}\n", .{an.lines});
    try out.print("skipped: {d} (lines that are not JSON records)\n", .{an.skipped});
    try out.print("parts:   {d}\n", .{counted});
    try out.print("known:   {d}\n", .{known_total});
    try out.print("unknown: {d}\n", .{unknown_total});
    try out.print("coverage: {d:.4}%\n", .{coverage});

    if (an.unknown.count() > 0) {
        const list = try gpa.alloc(Counted, an.unknown.count());
        defer gpa.free(list);
        var idx: usize = 0;
        var iu2 = an.unknown.iterator();
        while (iu2.next()) |e| : (idx += 1) list[idx] = .{ .key = e.key_ptr.*, .count = e.value_ptr.* };
        std.mem.sort(Counted, list, {}, byCountDesc);
        try out.print("\nUNKNOWN parts:\n", .{});
        for (list) |c| try out.print("  {d:>10}  {s}\n", .{ c.count, c.key });
    }

    if (verbose) {
        const list = try gpa.alloc(Counted, an.known.count());
        defer gpa.free(list);
        var idx: usize = 0;
        var ik = an.known.iterator();
        while (ik.next()) |e| : (idx += 1) list[idx] = .{ .key = e.key_ptr.*, .count = e.value_ptr.* };
        std.mem.sort(Counted, list, {}, byCountDesc);
        try out.print("\nFEATURES ({d}):\n", .{list.len});
        for (list) |c| try out.print("  {d:>10}  {s}\n", .{ c.count, c.key });
    }

    try out.flush();
    if (unknown_total > 0) return error.IncompleteCoverage;
}