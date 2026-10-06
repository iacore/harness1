//! Prints how a turn's Djot is drawn: the rows `ui/markup.zig` makes, escapes
//! and all, so the styling can be seen in a terminal.
//!
//!   zig build --build-file ./build.research.zig markup_probe
//!
//! No network and no terminal state: it writes the rows and stops.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const markup = @import("markup");

const sample =
    \\# Turns
    \\
    \\A turn is *the text the model sees*, and its _structure_ is tags.
    \\
    \\- a bullet
    \\- another, with `code` in it
    \\
    \\1. first
    \\2. second
    \\
    \\> a quotation
    \\
    \\---
    \\
    \\| a | b |
    \\|---|---|
    \\| 1 | 2 |
    \\
    \\```pikchr
    \\box "a diagram"
    \\```
    \\
    \\See [the manual](https://djot.net).
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var rows = try markup.render(gpa, sample, 60, null);
    defer {
        for (rows.items) |line| gpa.free(line);
        rows.deinit(gpa);
    }
    for (rows.items) |line| {
        write(line);
        write("\r\n");
    }
}

fn write(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = linux.write(posix.STDOUT_FILENO, bytes.ptr + offset, bytes.len - offset);
        if (count == 0 or count > bytes.len - offset) return;
        offset += count;
    }
}