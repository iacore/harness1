//! Clears the scrollback and prints text in one transaction, so kitty never
//! draws the cleared screen without the text in it.
//!
//! A scratch program, not part of the library: it wants a terminal, so it is
//! neither installed nor built by the default step.
//!
//!   zig build --build-file ./build.research.zig kitty_probe
//!
//! Run it in kitty: the history above the window goes and the lines below
//! appear together. Run it under `strace -e trace=write,writev` to see that the
//! erase and the text leave in a single call.

const std = @import("std");
const kitty = @import("kitty");

const text =
    \\scrollback erased, and this text arrived with it
    \\one call: no intermediate frame was drawn
    \\
;

pub fn main() !void {
    const clear = kitty.erase_screen ++ kitty.erase_scrollback ++ kitty.cursor_home;
    try kitty.writeParts(&.{ clear, text });
}