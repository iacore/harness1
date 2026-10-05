//! Sessions on disk: where the world file is, and what a run reads from it
//! before the TUI starts.
//!
//! A session is one run of this program — its turn tree, which is what
//! `editor.zig` writes into the world (`research/world.dj`: the world is where
//! turns live, and one world, not one per run). The store is `core/world.zig`:
//! one mapped file, so a run appends a session and the next run reads it back
//! without a format of our own.
//!
//! The file is `$XDG_STATE_HOME/run1/world`, or `~/.local/state/run1/world`
//! when that is unset — state, not cache, because a session is what a resume
//! needs and no cache is allowed to drop it.

const std = @import("std");
const Io = std.Io;
const run1 = @import("run1");
const world = run1.world;

/// A long conversation fits; the file is mapped rather than read whole, and it
/// is only appended to.
pub const capacity = 1 << 20;

/// Opens the world, making the directory and the file when they are absent.
pub fn open(gpa: std.mem.Allocator, io: Io, environ_map: *const std.process.Environ.Map) !world.World {
    const directory = try directoryPath(gpa, environ_map);
    defer gpa.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const file = try std.fs.path.join(gpa, &.{ directory, "world" });
    defer gpa.free(file);
    return world.World.open(gpa, io, file, capacity);
}

/// How many sessions the world holds.
pub fn count(w: *world.World) usize {
    const list = w.getField("sessions") orelse return 0;
    return if (w.items(list)) |items| items.len else 0;
}

/// What the picker shows for session `index`: the name that run filed itself
/// under.
pub fn name(w: *world.World, index: usize) []const u8 {
    const list = w.getField("sessions") orelse return "";
    const items = w.items(list) orelse return "";
    if (index >= items.len) return "";
    const session = w.asStruct(items[index]) orelse return "";
    const field = w.get(session, "name") orelse return "";
    return w.text(field) orelse "";
}

/// The directory the world lives in, which the caller frees.
fn directoryPath(gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]u8 {
    if (environ_map.get("XDG_STATE_HOME")) |state| return std.fs.path.join(gpa, &.{ state, "run1" });
    const home = environ_map.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "run1" });
}

test "the world's directory follows XDG_STATE_HOME, then HOME" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try env.put("HOME", "/home/someone");
    const under_home = try directoryPath(gpa, &env);
    defer gpa.free(under_home);
    try std.testing.expectEqualStrings("/home/someone/.local/state/run1", under_home);

    try env.put("XDG_STATE_HOME", "/state");
    const under_state = try directoryPath(gpa, &env);
    defer gpa.free(under_state);
    try std.testing.expectEqualStrings("/state/run1", under_state);
}
