//! The run1 program. It has two modes: the TUI when stdin is a terminal, and
//! the CLI when it is not — or when `--print` asks for it. Which one runs is
//! all this file decides; the modes are `tui.zig` and `cli.zig`, and everything
//! terminal-related is `kitty.zig`.
//!
//! Three flags reach the TUI: `-c` resumes the last session the world holds,
//! `--resume` opens the picker over all of them, and `--print` (`-p`) asks for
//! the CLI instead. The sessions themselves are `session.zig`.

const std = @import("std");
const cli = @import("cli.zig");
const tui = @import("tui.zig");

pub fn main(init: std.process.Init) !void {
    const wanted = parse(init);
    if (wanted.print) return cli.run(init);
    tui.run(init, .{ .resume_last = wanted.resume_last, .resume_pick = wanted.resume_pick }) catch |err| switch (err) {
        // No terminal to draw on: the CLI carries the same prompt.
        error.NotATerminal => return cli.run(init),
        else => return err,
    };
}

/// What the command line asked for. No flag is a fresh session, which the store
/// still gains a row for on the way out.
const Requested = struct {
    print: bool = false,
    resume_last: bool = false,
    resume_pick: bool = false,
};

fn parse(init: std.process.Init) Requested {
    var wanted: Requested = .{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip(); // the program's own name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) wanted.print = true;
        if (std.mem.eql(u8, arg, "-c")) wanted.resume_last = true;
        if (std.mem.eql(u8, arg, "--resume")) wanted.resume_pick = true;
    }
    return wanted;
}
