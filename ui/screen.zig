//! The frame: the rows to paint, and the diff against what is already on the
//! screen. omp's TUI works this way — an engine owns the frame and a component
//! only describes rows — and the reason is the drawing: a keystroke rewrites
//! the rows that changed instead of clearing the screen, so there is no flicker
//! and the terminal keeps what it had.

const std = @import("std");
const Allocator = std.mem.Allocator;
const kitty = @import("kitty.zig");

pub const Screen = struct {
    gpa: Allocator,
    /// The frame being built.
    rows: std.ArrayList([]u8) = .empty,
    /// What is on the screen now.
    shown: std.ArrayList([]u8) = .empty,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    height: usize = 24,
    /// Set while the terminal holds something this did not draw.
    damaged: bool = true,

    pub fn init(gpa: Allocator) Screen {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Screen) void {
        freeRows(self.gpa, &self.rows);
        freeRows(self.gpa, &self.shown);
        self.rows.deinit(self.gpa);
        self.shown.deinit(self.gpa);
    }

    /// Starts a frame. The rows of the last one are dropped.
    pub fn clear(self: *Screen) void {
        freeRows(self.gpa, &self.rows);
    }

    /// Adds a row. The screen takes a copy, so the caller owns nothing after.
    pub fn add(self: *Screen, text: []const u8) !void {
        try self.rows.append(self.gpa, try self.gpa.dupe(u8, text));
    }

    /// Where the cursor is left when the frame is painted, 0-based.
    pub fn place(self: *Screen, row: usize, col: usize) void {
        self.cursor_row = row;
        self.cursor_col = col;
    }

    /// Forgets what is on the screen, so the next frame paints every row. For
    /// when the terminal has been borrowed by something else.
    pub fn invalidate(self: *Screen) void {
        freeRows(self.gpa, &self.shown);
        self.damaged = true;
    }

    /// Paints the rows that differ from the last frame, clears the ones this
    /// frame does not reach, and puts the cursor where it was asked to go.
    pub fn flush(self: *Screen) void {
        if (self.damaged) {
            kitty.write(kitty.erase_screen ++ kitty.cursor_home) catch {};
            // Nothing is on the screen now, so every row paints.
            freeRows(self.gpa, &self.shown);
            self.damaged = false;
        }
        const limit = @min(self.rows.items.len, self.height);
        var row: usize = 0;
        while (row < limit) : (row += 1) {
            const text = self.rows.items[row];
            if (row < self.shown.items.len and std.mem.eql(u8, text, self.shown.items[row])) continue;
            kitty.print("\x1b[{d};1H\x1b[2K", .{row + 1}) catch {};
            kitty.write(text) catch {};
        }
        row = limit;
        while (row < self.shown.items.len and row < self.height) : (row += 1) {
            kitty.print("\x1b[{d};1H\x1b[2K", .{row + 1}) catch {};
        }
        kitty.print("\x1b[{d};{d}H", .{ self.cursor_row + 1, self.cursor_col + 1 }) catch {};

        // What was just painted becomes what is on the screen.
        freeRows(self.gpa, &self.shown);
        const recycled = self.shown;
        self.shown = self.rows;
        self.rows = recycled;
    }
};

fn freeRows(gpa: Allocator, rows: *std.ArrayList([]u8)) void {
    for (rows.items) |text| gpa.free(text);
    rows.clearRetainingCapacity();
}
