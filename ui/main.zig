//! The run1 program. It has two modes: the TUI when stdin is a terminal, and
//! the CLI when it is not — or when `--print` asks for it. Which one runs is
//! all this file decides; the modes are `tui.zig` and `cli.zig`, and everything
//! terminal-related is `kitty.zig`.

const std = @import("std");
const cli = @import("cli.zig");
const tui = @import("tui.zig");

pub fn main(init: std.process.Init) !void {
    if (printRequested(init)) return cli.run(init);
    tui.run(init) catch |err| switch (err) {
        // No terminal to draw on: the CLI carries the same prompt.
        error.NotATerminal => return cli.run(init),
        else => return err,
    };
}

/// Whether `--print` (or `-p`) is on the command line, which asks for the CLI
/// even on a terminal.
fn printRequested(init: std.process.Init) bool {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip(); // the program's own name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) return true;
    }
    return false;
}
