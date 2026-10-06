//! Renders a ```pikchr diagram to a PNG and paints it in the terminal, so the
//! two halves the TUI joins — `ui/pikchr.zig` and `ui/graphics.zig` — can be
//! seen working on their own.
//!
//!   zig build --build-file ./build.research.zig pikchr_probe
//!
//! Needs `pikchr` and a rasterizer on the PATH; it says so and stops when they
//! are missing. Run it in kitty: the box below is a picture, not characters.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const pikchr = @import("pikchr");
const graphics = @import("graphics");

const sample =
    \\arrow right 200% "Markdown" "Source"
    \\box rad 10px "Markdown" "Formatter" "(markdown.c)" fit
    \\arrow right 200% "HTML+SVG" "Output"
    \\arrow <-> down 70% from last box.s
    \\box same "Pikchr" "Formatter" "(pikchr.c)" fit
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const tools = pikchr.Tools.find(io, gpa) orelse {
        std.debug.print("pikchr (or a rasterizer) is not on the PATH\n", .{});
        return error.NoPikchr;
    };
    const image = (try tools.render(io, gpa, sample)) orelse {
        std.debug.print("pikchr refused the diagram\n", .{});
        return error.RenderFailed;
    };
    defer image.deinit(gpa);
    std.debug.print("png {d}x{d}, {d} bytes\n", .{ image.width, image.height, image.png.len });

    // Cells, from the terminal's own size when it reports pixels.
    const size = windowSize() orelse Size{ .rows = 24, .cols = 80 };
    var cell_width: f32 = 9;
    var cell_height: f32 = 18;
    if (windowPixels()) |pixels| {
        cell_width = @as(f32, @floatFromInt(pixels.cols)) / @as(f32, @floatFromInt(size.cols));
        cell_height = @as(f32, @floatFromInt(pixels.rows)) / @as(f32, @floatFromInt(size.rows));
    }
    const cols = @max(1, @as(usize, @intFromFloat(image.width / cell_width)));
    const rows = @max(1, @as(usize, @intFromFloat(image.height / cell_height)));

    const id: u32 = 0x00c0ffee;
    try graphics.transmit(gpa, id, image.png, cols, rows);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| gpa.free(line);
        lines.deinit(gpa);
    }
    try graphics.placeholders(gpa, id, cols, rows, &lines);
    for (lines.items) |line| {
        write(line);
        write("\r\n");
    }
    std.debug.print("painted {d}x{d} cells\n", .{ cols, rows });
}

const Size = struct { rows: usize, cols: usize };

fn windowSize() ?Size {
    const window = winsize() orelse return null;
    if (window.row == 0 or window.col == 0) return null;
    return .{ .rows = window.row, .cols = window.col };
}

fn windowPixels() ?Size {
    const window = winsize() orelse return null;
    if (window.xpixel == 0 or window.ypixel == 0) return null;
    return .{ .rows = window.ypixel, .cols = window.xpixel };
}

fn winsize() ?posix.winsize {
    var window: posix.winsize = undefined;
    const request = @as(u32, @intCast(linux.T.IOCGWINSZ));
    if (linux.ioctl(posix.STDOUT_FILENO, request, @intFromPtr(&window)) != 0) return null;
    return window;
}

fn write(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = linux.write(posix.STDOUT_FILENO, bytes.ptr + offset, bytes.len - offset);
        if (count == 0 or count > bytes.len - offset) return;
        offset += count;
    }
}