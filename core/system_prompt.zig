//! The system prompt: its words, its sections, and the feature vocabulary it
//! carries, written as the node tree from `turns.zig` and printed to a writer.
//! The vocabulary itself is the data in `omp_features.zig`; this file only
//! decides its shape.

const std = @import("std");
const Io = std.Io;
const turns = @import("turns.zig");
const omp = @import("omp_features.zig");
const Node = turns.Node;

/// Prints the whole system prompt to `writer`.
pub fn systemPrompt(writer: *Io.Writer) !void {
    try turns.write(writer, document);
}

// ── The document ────────────────────────────────────────────────────────────

const p_implemented: Node = .{ .element = .{ .tag = "p", .children = &[_]Node{
    .{ .text = "This harness implements the features marked " },
    .{ .element = .{ .tag = "code", .children = &[_]Node{.{ .text = "[+]" }} } },
    .{ .text = ". A feature listed without " },
    .{ .element = .{ .tag = "code", .children = &[_]Node{.{ .text = "[+]" }} } },
    .{ .text = " exists in the vocabulary but is not implemented here." },
} } };

const p_autonomy: Node = .{ .element = .{ .tag = "p", .children = &[_]Node{
    .{ .text = "You are not required to do everything you are told. Where you judge an instruction wrong, you may refuse it; where the task asks for a feature that is not implemented here, you may stop and ask for it to be implemented." },
} } };

const p_escalate: Node = .{ .element = .{ .tag = "p", .children = &[_]Node{
    .{ .text = "Escalate when you need to reach the operator; the " },
    .{ .element = .{ .tag = "code", .children = &[_]Node{.{ .text = "escalate" }} } },
    .{ .text = " tool carries the instruction you object to and why to the operator." },
} } };

/// The feature vocabulary as text nodes: a label line, a line per value, and a
/// blank line between kinds, with the tool operations after. Composed at compile
/// time, so the document is a constant.
const vocabulary: []const Node = blk: {
    @setEvalBranchQuota(200_000);
    var nodes: []const Node = &[_]Node{};
    for (std.enums.values(omp.Kind)) |kind| {
        nodes = nodes ++ &[_]Node{.{ .text = std.fmt.comptimePrint("{s}:\n", .{@tagName(kind)}) }};
        for (omp.table(kind)) |value| {
            nodes = nodes ++ &[_]Node{.{ .text = std.fmt.comptimePrint("  {s} {s}\n", .{ if (omp.isImplemented(kind, value)) "[+]" else "[ ]", value }) }};
        }
        nodes = nodes ++ &[_]Node{.{ .text = "\n" }};
    }
    nodes = nodes ++ &[_]Node{.{ .text = "tool_operation:\n" }};
    for (omp.operation_tools) |tool| {
        for (omp.operation_keys) |key| {
            const values = omp.operationValues(tool, key) orelse continue;
            for (values) |value| {
                nodes = nodes ++ &[_]Node{.{ .text = std.fmt.comptimePrint("  {s} {s}.{s}.{s}\n", .{ if (omp.isImplemented(.tool, tool)) "[+]" else "[ ]", tool, key, value }) }};
            }
        }
    }
    break :blk nodes;
};

const implemented_section: Node = .{ .element = .{
    .tag = "section",
    .name = "Implemented features",
    .children = implemented_lines,
} };

const implemented_lines: []const Node = blk: {
    var nodes: []const Node = &[_]Node{.{ .text = "\n" }};
    if (omp.implemented.len == 0) {
        nodes = nodes ++ &[_]Node{.{ .text = "none\n" }};
    } else {
        for (omp.implemented) |f| {
            nodes = nodes ++ &[_]Node{.{ .text = std.fmt.comptimePrint("{s}: {s}\n", .{ @tagName(f.kind), f.value }) }};
        }
    }
    break :blk nodes;
};

const section_children: []const Node = blk: {
    @setEvalBranchQuota(200_000);
    var nodes: []const Node = &[_]Node{.{ .text = "\n" }};
    nodes = nodes ++ &[_]Node{
        p_implemented, .{ .text = "\n" },
        p_autonomy,    .{ .text = "\n" },
        p_escalate,    .{ .text = "\n\n" },
    };
    nodes = nodes ++ vocabulary;
    nodes = nodes ++ &[_]Node{ .{ .text = "\n" }, implemented_section, .{ .text = "\n" } };
    break :blk nodes;
};

const document: []const Node = &[_]Node{
    .{ .element = .{ .tag = "section", .name = "Harness features", .children = section_children } },
    .{ .text = "\n" },
};

test "the prompt carries the whole vocabulary as one document" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try systemPrompt(&out.writer);
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "<section name=\"Harness features\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<code>escalate</code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<section name=\"Implemented features\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  [ ] bash\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  [ ] hub.op.jobs\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "</section>\n"));
}
