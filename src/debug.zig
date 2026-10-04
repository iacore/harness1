//! Diagnostics shared by the harness's modules: one message shape, handed to
//! the caller rather than reached for globally.

const std = @import("std");
const Io = std.Io;

/// A caller-owned logger that hands each diagnostic to `sink`, a comptime
/// function of `(context, comptime message_id, comptime format, args)`.
///
/// `comptime message_id`/`format` and generic `args` mean the sink receives the
/// arguments themselves, not a rendered string: it can render the line *and*
/// keep the arguments as data. A handler that is a value cannot, because
/// `args` is generic.
pub fn DebugLogger(comptime sink: anytype) type {
    return struct {
        context: *anyopaque,

        /// `message_id` is identifier-shaped and names what happened,
        /// `keys:python_helper_unavailable`, whose `keys:` prefix is the
        /// scope. Together with `format` and `args` it is the whole message.
        pub fn report(
            self: @This(),
            comptime message_id: []const u8,
            comptime format: []const u8,
            args: anytype,
        ) void {
            sink(self.context, message_id, format, args);
        }
    };
}

/// The sink that writes `message_id: message` lines to a `*Io.Writer`.
pub fn writeLine(
    context: *anyopaque,
    comptime message_id: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    const out: *Io.Writer = @ptrCast(@alignCast(context));
    // A sink that cannot write has nowhere to report it.
    out.print("{s}: ", .{message_id}) catch return;
    out.print(format, args) catch return;
    out.writeAll("\n") catch return;
}

/// A logger that writes to `out`.
pub fn writer(out: *Io.Writer) DebugLogger(writeLine) {
    return .{ .context = out };
}