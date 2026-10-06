//! Pikchr diagrams: a ```pikchr fenced block's text to a PNG, by running the
//! `pikchr` command (which prints SVG) and a rasterizer (which prints a PNG).
//! Nothing is linked in, so a machine without those commands simply has no
//! diagrams — the caller keeps the block as text, which is the same thing a
//! fence with an unknown language does.
//!
//! `research/rich-text.dj` fixes why: a turn's rendering ends at rows, and an
//! image is the one exception — it reaches the terminal as a picture, not as
//! cells, so its pixels come from somewhere outside this program.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// A rendered diagram, and the size it should occupy on screen, in PNG pixels —
/// which the caller divides by the terminal's cell size to get cells.
pub const Image = struct {
    png: []u8,
    width: f32,
    height: f32,

    pub fn deinit(self: Image, gpa: Allocator) void {
        gpa.free(self.png);
    }
};

/// The commands the conversion needs, resolved once. Absent `pikchr` or absent
/// rasterizer means no diagrams.
pub const Tools = struct {
    raster: Rasterizer,

    pub const Rasterizer = enum {
        rsvg_convert,
        resvg,
        magick,

        fn argv(self: Rasterizer, svg: []const u8, png: []const u8) []const []const u8 {
            return switch (self) {
                .rsvg_convert => &.{ "rsvg-convert", "-f", "png", "-o", png, svg },
                .resvg => &.{ "resvg", svg, png },
                .magick => &.{ "magick", "-background", "none", svg, png },
            };
        }

        fn probe(self: Rasterizer) []const []const u8 {
            return switch (self) {
                .rsvg_convert => &.{"rsvg-convert"},
                .resvg => &.{"resvg"},
                .magick => &.{ "magick", "-version" },
            };
        }
    };

    /// Resolves `pikchr` and a rasterizer, or null when either is missing.
    pub fn find(io: Io, gpa: Allocator) ?Tools {
        if (!runs(io, gpa, &.{"pikchr"})) return null;
        const in_order = [_]Rasterizer{ .rsvg_convert, .resvg, .magick };
        for (in_order) |raster| {
            if (runs(io, gpa, raster.probe())) return .{ .raster = raster };
        }
        return null;
    }

    /// Renders `source` to a PNG, or null when `pikchr` refused it — a bad
    /// diagram is a reason to show the source, not to fail the draw.
    pub fn render(self: Tools, io: Io, gpa: Allocator, source: []const u8) !?Image {
        var name_buffer: [64]u8 = undefined;
        const dir = std.fmt.bufPrint(&name_buffer, "/tmp/run1-pikchr-{d}-{d}", .{
            std.os.linux.getpid(),
            next(io),
        }) catch return null;
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch return null;
        defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

        const source_path = try std.fmt.allocPrint(gpa, "{s}/in.pikchr", .{dir});
        defer gpa.free(source_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = source });

        const drawn = try std.process.run(gpa, io, .{
            .argv = &.{ "pikchr", "--svg-only", source_path },
            .stdout_limit = .limited(8 << 20),
        });
        defer gpa.free(drawn.stdout);
        defer gpa.free(drawn.stderr);
        if (!drawn.term.success() or drawn.stdout.len == 0) return null;

        const svg_path = try std.fmt.allocPrint(gpa, "{s}/in.svg", .{dir});
        defer gpa.free(svg_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = svg_path, .data = drawn.stdout });

        const png_path = try std.fmt.allocPrint(gpa, "{s}/out.png", .{dir});
        defer gpa.free(png_path);
        const raster = try std.process.run(gpa, io, .{
            .argv = self.raster.argv(svg_path, png_path),
            .stdout_limit = .limited(1 << 16),
        });
        defer gpa.free(raster.stdout);
        defer gpa.free(raster.stderr);
        if (!raster.term.success()) return null;

        const png = try std.Io.Dir.cwd().readFileAlloc(io, png_path, gpa, .limited(64 << 20));
        errdefer gpa.free(png);
        const pixels = pngSize(png) orelse return null;
        return .{
            .png = png,
            .width = @floatFromInt(pixels.w),
            .height = @floatFromInt(pixels.h),
        };
    }
};

/// Runs `argv` and reports whether it could be started at all, which is the
/// only question here: a command that exists but refuses its arguments still
/// exists.
fn runs(io: Io, gpa: Allocator, argv: []const []const u8) bool {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 12),
        .stderr_limit = .limited(1 << 12),
    }) catch return false;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    return true;
}

/// The width and height `png` announces in its `IHDR` — the one place the
/// rasterizer's output carries them.
fn pngSize(png: []const u8) ?struct { w: u32, h: u32 } {
    if (png.len < 24) return null;
    if (!std.mem.eql(u8, png[0..8], &[8]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a })) return null;
    if (!std.mem.eql(u8, png[12..16], "IHDR")) return null;
    return .{
        .w = std.mem.readInt(u32, png[16..20], .big),
        .h = std.mem.readInt(u32, png[20..24], .big),
    };
}

var counter: std.atomic.Value(u32) = .init(0);

/// A number no two renders in this process share, so their scratch directories
/// do not collide. The pid in the name keeps two processes apart.
fn next(io: Io) u32 {
    _ = io;
    return counter.fetchAdd(1, .monotonic);
}

test "the PNG header is where the size is" {
    // A one-pixel PNG, header only is enough for the reader.
    var png: [24]u8 = undefined;
    @memset(&png, 0);
    png[0] = 0x89;
    png[1] = 'P';
    png[2] = 'N';
    png[3] = 'G';
    png[4] = 0x0d;
    png[5] = 0x0a;
    png[6] = 0x1a;
    png[7] = 0x0a;
    std.mem.writeInt(u32, png[16..20], 113, .big);
    std.mem.writeInt(u32, png[20..24], 77, .big);
    std.mem.copyForwards(u8, png[12..16], "IHDR");
    const size = pngSize(&png) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 113), size.w);
    try std.testing.expectEqual(@as(u32, 77), size.h);
    try std.testing.expect(pngSize("too short") == null);
}