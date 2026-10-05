//! A turn is written as a tree of nodes and printed to a writer rather than
//! assembled into a string. `Node` is the whole of the model: text, or an
//! element with a tag, an optional `name` attribute and children. This file is
//! only the tree and how it prints; what a particular turn says is its own
//! definition — the system prompt's is `system_prompt.zig`.

const std = @import("std");
const Io = std.Io;

/// One piece of a turn.
pub const Node = union(enum) {
    text: []const u8,
    element: Element,

    /// An XML element: a tag, an optional `name` attribute, and children. An
    /// element with no children prints as an empty pair of tags.
    pub const Element = struct {
        tag: []const u8,
        name: ?[]const u8 = null,
        children: []const Node = &.{},
    };

    /// Writes the node to `writer`: text as itself, an element as its tag with
    /// the `name` attribute, then its children and the closing tag.
    pub fn print(self: Node, writer: *Io.Writer) !void {
        switch (self) {
            .text => |text| try writer.writeAll(text),
            .element => |element| {
                try writer.writeByte('<');
                try writer.writeAll(element.tag);
                if (element.name) |name| try writer.print(" name=\"{s}\"", .{name});
                try writer.writeByte('>');
                for (element.children) |child| try child.print(writer);
                try writer.writeAll("</");
                try writer.writeAll(element.tag);
                try writer.writeByte('>');
            },
        }
    }
};

/// Builds a turn from its nodes: the whole of turning a definition into bytes.
pub fn write(writer: *Io.Writer, nodes: []const Node) !void {
    for (nodes) |node| try node.print(writer);
}
