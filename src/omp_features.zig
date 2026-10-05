//! The feature vocabulary of the harness: every feature observed across the
//! recorded session corpus, grouped by the slot a value occupies, plus the
//! subset this harness implements today.
//!
//! `systemPrompt` renders all of it as a rope, so the agent reads the full
//! list of potential features and which are implemented. A potential feature
//! that is not implemented is something the agent must stop and ask for rather
//! than guess at.
//!
//! The tables are the closed vocabulary. Adding a name here only declares it
//! possible; implementing it means acting on it and recording that in
//! `implemented`.

const std = @import("std");

/// The slot a feature value occupies. A name is a feature only for its slot:
/// `hub` is a tool and never a mode.
pub const Kind = enum {
    record_type,
    role,
    block_kind,
    tool,
    custom,
    custom_message,
    mode,
    thinking_level,
    configured_level,
    model_change_role,
    session_exit_kind,
    session_exit_reason,
    vibe_action,
    hud_visibility,
    title_source,
    title_change_trigger,
    agent,
    model_role,
    output_schema_mode,
    compaction_method,
    model_usage_purpose,
    model_usage_api,
    api,
    provider,
    stop_reason,
    user_attribution,
    credential_provider,
    ttsr_rule,
};

// ── Potential features ──────────────────────────────────────────────────────

pub const record_types = [_][]const u8{
    "message",               "custom",         "custom_message",
    "mode_change",           "model_change",   "model_usage",
    "thinking_level_change", "session",        "session_init",
    "title",                 "title_change",   "service_tier_change",
    "credential_pin",        "ttsr_injection", "compaction",
};

pub const roles = [_][]const u8{
    "assistant",       "bashExecution",   "developer",
    "fileMention",     "pythonExecution", "toolResult",
    "user",
};

pub const block_kinds = [_][]const u8{ "image", "text", "thinking", "video" };

pub const tools = [_][]const u8{
    "advise",                                "analyze_files",
    "ask",                                   "ast_edit",
    "ast_grep",                              "bash",
    "bid",                                   "browser",
    "cd",                                    "debug",
    "edit",                                  "escalate",
    "eval",                                  "find",
    "fuzzy_find",                            "generate_image",
    "git_file_diff",                         "git_hunk",
    "git_overview",                          "glob",
    "goal",                                  "grep",
    "hub",                                   "inspect_image",
    "irc",                                   "job",
    "learn",                                 "ls",
    "lsp",                                   "manage_skill",
    "mcp__canva_commit_editing_transaction", "mcp__canva_create_design_from_candidate",
    "mcp__canva_generate_design",            "mcp__canva_perform_editing_operations",
    "mcp__canva_start_editing_transaction",  "mcp__canva_upload_asset_from_url",
    "mcp__codegraph_explore",                "memory_edit",
    "memory_forget",                         "memory_recall",
    "memory_remember",                       "pentest_add_finding",
    "pentest_report",                        "pentest_sandbox_run",
    "propose_commit",                        "read",
    "recall",                                "reflect",
    "report_tool_issue",                     "resolve",
    "retain",                                "search",
    "session_search",                        "task",
    "todo",                                  "tui",
    "vibe_kill",                             "vibe_send",
    "vibe_spawn",                            "vibe_wait",
    "wait",                                  "web_search",
    "worktree",                              "write",
    "xd://recall",                           "yield",
};

pub const custom_types = [_][]const u8{
    "dev.deepseek-unrestricted.state", "goal-completed",
    "session_exit",                    "todo_hud_state",
    "tool_execution_start",            "user_todo_edit",
    "vibe-session-lifecycle",
};

pub const custom_message_types = [_][]const u8{
    "advisor",                      "async-result",
    "background-tan-dispatch",      "collab-prompt",
    "goal-continuation",            "goal-mode-context",
    "handoff",                      "image-attachment",
    "image-attachment-description", "interrupted-thinking",
    "irc:incoming",                 "jevify-notice",
    "launch-completion",            "lsp-late-diagnostic",
    "mid-run-todo-nudge",           "orchestrate-notice",
    "plan-mode-context",            "plan-mode-reference",
    "prewalk-checklist",            "resolve-reminder",
    "session-stop-continuation",    "skill-prompt",
    "thinking-loop-redirect",       "todo-error-reminder",
    "tool-call-loop-redirect",      "ttsr-injection",
    "ultrathink-notice",            "vibe-mode-context",
    "workflow-notice",              "xdev-mount-notice",
};

pub const modes = [_][]const u8{ "goal", "goal_paused", "none", "plan", "plan_paused", "vibe" };

pub const thinking_levels = [_][]const u8{ "high", "low", "max", "medium", "minimal", "off", "xhigh" };
pub const configured_levels = [_][]const u8{ "auto", "high", "low", "max", "minimal", "off", "xhigh" };

pub const model_change_roles = [_][]const u8{ "default", "fallback", "slow", "smol", "temporary" };

pub const session_exit_kinds = [_][]const u8{ "fatal", "normal", "process_exit", "signal" };
pub const session_exit_reasons = [_][]const u8{
    "dispose", "exit", "sigint", "sighup", "sigterm", "uncaught_exception",
};

pub const vibe_actions = [_][]const u8{ "spawn", "tombstone", "turn-settled", "turn-started" };
pub const hud_visibilities = [_][]const u8{"dismissed"};

pub const title_sources = [_][]const u8{"auto"};
pub const title_change_triggers = [_][]const u8{"replan"};

pub const agents = [_][]const u8{ "reviewer", "scout", "sonic", "task" };
pub const model_roles = [_][]const u8{ "slow", "smol" };
pub const output_schema_modes = [_][]const u8{ "permissive", "strict" };

pub const compaction_methods = [_][]const u8{ "default", "handoff", "snapcompact", "soft" };

pub const model_usage_purposes = [_][]const u8{ "auto-thinking", "find", "judge_batch" };
pub const model_usage_apis = [_][]const u8{ "openai-completions", "openrouter-decisions" };

pub const apis = [_][]const u8{
    "anthropic-messages", "ollama-chat", "openai-completions", "openai-responses", "openrouter",
};

pub const providers = [_][]const u8{
    "anthropic",   "deepseek",     "kimi-code",  "lithosai",
    "moonshot",    "moonshot-cn",  "ollama",     "ollama-cloud",
    "opencode-go", "opencode-zen", "openrouter", "siliconflow-cn",
};

pub const stop_reasons = [_][]const u8{ "aborted", "error", "length", "stop", "toolUse" };
pub const user_attributions = [_][]const u8{ "agent", "user" };
pub const credential_providers = [_][]const u8{"kimi-code"};

pub const ttsr_rules = [_][]const u8{
    "go-new-expr",              "go-rand-v2",
    "go-range-int",             "rs-future-prelude",
    "rs-match-ergonomics",      "rs-parking-lot",
    "rs-result-type",           "ts-import-type",
    "ts-no-any",                "ts-no-dynamic-import",
    "ts-no-inline-cast-access", "ts-no-local-is-record",
    "ts-no-return-type",        "ts-no-test-timers",
    "ts-no-tiny-functions",     "ts-promise-with-resolvers",
    "ts-redundant-clear-guard", "ts-set-map",
};

/// The `details` keys whose value is a tool's own operation name. The value is
/// a feature in its own right: `hub op=jobs` is the hub tool's jobs feature.
pub const operation_keys = [_][]const u8{ "op", "action", "status", "language", "kind" };

/// The known operations of `tool`.`key`, or null when this harness models no
/// operation for that pair.
pub fn operationValues(tool: []const u8, key: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, tool, "hub") and std.mem.eql(u8, key, "op"))
        return &.{ "cancel", "describe", "inbox", "jobs", "list", "logs", "restart", "send", "start", "stop", "wait" };
    if (std.mem.eql(u8, tool, "todo") and std.mem.eql(u8, key, "op"))
        return &.{ "append", "block", "done", "drop", "init", "rm", "start", "unblock", "view" };
    if (std.mem.eql(u8, tool, "browser") and std.mem.eql(u8, key, "action"))
        return &.{ "close", "open", "run" };
    if (std.mem.eql(u8, tool, "irc") and std.mem.eql(u8, key, "op"))
        return &.{ "inbox", "list", "send", "wait" };
    if (std.mem.eql(u8, tool, "goal") and std.mem.eql(u8, key, "op"))
        return &.{ "complete", "get" };
    if (std.mem.eql(u8, tool, "manage_skill") and std.mem.eql(u8, key, "action"))
        return &.{ "create", "delete", "update" };
    if (std.mem.eql(u8, tool, "lsp") and std.mem.eql(u8, key, "action"))
        return &.{ "code_actions", "diagnostics", "hover", "reload", "rename", "rename_file", "status", "symbols" };
    if (std.mem.eql(u8, tool, "resolve") and std.mem.eql(u8, key, "action"))
        return &.{"apply"};
    if (std.mem.eql(u8, tool, "memory_edit") and std.mem.eql(u8, key, "status"))
        return &.{ "deleted", "not_found", "updated" };
    if (std.mem.eql(u8, tool, "worktree") and std.mem.eql(u8, key, "op"))
        return &.{ "create", "list" };
    if (std.mem.eql(u8, tool, "vibe_wait") and std.mem.eql(u8, key, "op")) return &.{"wait"};
    if (std.mem.eql(u8, tool, "vibe_spawn") and std.mem.eql(u8, key, "op")) return &.{"spawn"};
    if (std.mem.eql(u8, tool, "vibe_send") and std.mem.eql(u8, key, "op")) return &.{"send"};
    if (std.mem.eql(u8, tool, "vibe_kill") and std.mem.eql(u8, key, "op")) return &.{"kill"};
    if (std.mem.eql(u8, tool, "wait") and std.mem.eql(u8, key, "op")) return &.{"wait"};
    if (std.mem.eql(u8, tool, "yield") and std.mem.eql(u8, key, "status"))
        return &.{ "aborted", "success" };
    if (std.mem.eql(u8, tool, "eval") and std.mem.eql(u8, key, "language"))
        return &.{ "js", "python" };
    if (std.mem.eql(u8, tool, "edit") and std.mem.eql(u8, key, "op")) return &.{"update"};
    if (std.mem.eql(u8, tool, "read") and std.mem.eql(u8, key, "kind")) return &.{"url"};
    return null;
}

// ── Implemented features ────────────────────────────────────────────────────

/// A feature this harness acts on. Every entry must also appear in the table
/// for its kind; the tables alone only make a feature possible.
pub const Feature = struct { kind: Kind, value: []const u8 };

/// The implemented subset. Empty until an agent loop acts on a feature; add an
/// entry at the same time the feature lands.
pub const implemented = [_]Feature{};

pub fn isImplemented(kind: Kind, value: []const u8) bool {
    for (implemented) |f| {
        if (f.kind == kind and std.mem.eql(u8, f.value, value)) return true;
    }
    return false;
}

/// The known values of `kind`.
pub fn table(kind: Kind) []const []const u8 {
    return switch (kind) {
        .record_type => &record_types,
        .role => &roles,
        .block_kind => &block_kinds,
        .tool => &tools,
        .custom => &custom_types,
        .custom_message => &custom_message_types,
        .mode => &modes,
        .thinking_level => &thinking_levels,
        .configured_level => &configured_levels,
        .model_change_role => &model_change_roles,
        .session_exit_kind => &session_exit_kinds,
        .session_exit_reason => &session_exit_reasons,
        .vibe_action => &vibe_actions,
        .hud_visibility => &hud_visibilities,
        .title_source => &title_sources,
        .title_change_trigger => &title_change_triggers,
        .agent => &agents,
        .model_role => &model_roles,
        .output_schema_mode => &output_schema_modes,
        .compaction_method => &compaction_methods,
        .model_usage_purpose => &model_usage_purposes,
        .model_usage_api => &model_usage_apis,
        .api => &apis,
        .provider => &providers,
        .stop_reason => &stop_reasons,
        .user_attribution => &user_attributions,
        .credential_provider => &credential_providers,
        .ttsr_rule => &ttsr_rules,
    };
}

// ── System prompt ───────────────────────────────────────────────────────────

/// A concatenation tree over the bytes of a string. The prompt composes as a
/// rope so its parts join without intermediate copies; flatten it only when the
/// bytes are needed.
pub const Rope = union(enum) {
    leaf: []const u8,
    concat: []const Rope,

    /// Byte length of the rope's content.
    pub fn length(self: Rope) usize {
        return switch (self) {
            .leaf => |s| s.len,
            .concat => |children| blk: {
                var total: usize = 0;
                for (children) |child| total += child.length();
                break :blk total;
            },
        };
    }

    /// Appends the rope's bytes, in order, to `bytes`.
    pub fn appendTo(self: Rope, bytes: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
        switch (self) {
            .leaf => |s| try bytes.appendSlice(allocator, s),
            .concat => |children| for (children) |child| try child.appendTo(bytes, allocator),
        }
    }

    /// Allocates the rope's content as one slice.
    pub fn flatten(self: Rope, allocator: std.mem.Allocator) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try self.appendTo(&bytes, allocator);
        return bytes.toOwnedSlice(allocator);
    }
};

const prompt_header =
    \\# Harness features
    \\
    \\This harness implements the features marked `[+]`. A feature listed
    \\without `[+]` exists in the vocabulary but is not implemented here: do
    \\not guess at it — stop and ask for it to be implemented.
    \\
    \\
;

const operation_tools = [_][]const u8{
    "browser",   "edit",        "eval",      "goal",       "hub",
    "irc",       "lsp",         "manage_skill", "memory_edit", "read",
    "resolve",   "todo",        "vibe_kill", "vibe_send",  "vibe_spawn",
    "vibe_wait", "wait",        "worktree",  "yield",
};

/// The system-prompt section as a rope: the full list of potential features,
/// each marked `[+]` when implemented, then the implemented subset. Leaves
/// borrow the tables, so the rope lives no longer than them.
pub fn systemPrompt(allocator: std.mem.Allocator) !Rope {
    var children: std.ArrayList(Rope) = .empty;
    errdefer children.deinit(allocator);

    try children.append(allocator, .{ .leaf = prompt_header });
    inline for (std.enums.values(Kind)) |kind| {
        try children.append(allocator, .{ .leaf = try std.fmt.allocPrint(allocator, "{s}:\n", .{@tagName(kind)}) });
        const values = table(kind);
        if (values.len == 0) {
            try children.append(allocator, .{ .leaf = "  (none)\n" });
        } else {
            for (values) |value| {
                try children.append(allocator, .{ .leaf = try std.fmt.allocPrint(allocator, "  {s} {s}\n", .{ if (isImplemented(kind, value)) "[+]" else "[ ]", value }) });
            }
        }
        try children.append(allocator, .{ .leaf = "\n" });
    }

    try children.append(allocator, .{ .leaf = "tool_operation:\n" });
    for (operation_tools) |tool| {
        for (operation_keys) |key| {
            const values = operationValues(tool, key) orelse continue;
            for (values) |value| {
                try children.append(allocator, .{ .leaf = try std.fmt.allocPrint(allocator, "  {s} {s}.{s}.{s}\n", .{ if (isImplemented(.tool, tool)) "[+]" else "[ ]", tool, key, value }) });
            }
        }
    }

    try children.append(allocator, .{ .leaf = "\n# Implemented features\n\n" });
    if (implemented.len == 0) {
        try children.append(allocator, .{ .leaf = "none\n" });
    } else {
        for (implemented) |f| {
            try children.append(allocator, .{ .leaf = try std.fmt.allocPrint(allocator, "{s}: {s}\n", .{ @tagName(f.kind), f.value }) });
        }
    }

    return .{ .concat = try children.toOwnedSlice(allocator) };
}

test "the rope holds the whole vocabulary, with nothing implemented yet" {
    inline for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(table(kind).len > 0 or kind == .hud_visibility);
    }
    try std.testing.expect(!isImplemented(.mode, "goal"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rope = try systemPrompt(arena.allocator());
    const text = try rope.flatten(arena.allocator());

    try std.testing.expectEqual(text.len, rope.length());
    try std.testing.expect(std.mem.indexOf(u8, text, "# Harness features") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Implemented features") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  [ ] bash\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  [ ] hub.op.jobs\n") != null);
}