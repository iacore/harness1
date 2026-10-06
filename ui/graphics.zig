//! The kitty graphics protocol, for the one thing the TUI draws that is not
//! text: a pikchr diagram. The picture is transmitted once as a *virtual
//! placement*, and then referred to by Unicode placeholder cells in the
//! transcript — so it moves, scrolls and erases with the text it sits among,
//! because to everything but the terminal it is text.
//!
//! Only the part this needs is here: transmit a PNG under an id, and lay out
//! the placeholder rows that point at it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const kitty = @import("kitty.zig");

/// The placeholder cell. U+10EEEE is a private-use character kitty reads as
/// "the image whose id is in this cell's foreground color", with the diacritics
/// that follow naming the row and column.
pub const cell = "\u{10EEEE}";

/// The combining mark that names a row, from kitty's
/// `gen/rowcolumn-diacritics.txt` (297 marks drawn from Unicode 6.0.0); index
/// i is row i. A row's first cell carries it and the rest inherit the column.
pub const row_diacritics = [_]u21{
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B,
    0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367,
    0x0368, 0x0369, 0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485,
    0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D,
    0x059E, 0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610,
    0x0611, 0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A,
    0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8, 0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF,
    0x06E0, 0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
    0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743, 0x0745, 0x0747, 0x0749,
    0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817,
    0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822, 0x0823,
    0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
};

/// The most base64 one escape carries. Four bytes of base64 per three of PNG,
/// so a 3072-byte slice becomes a 4096-character payload.
const chunk = 3072;

/// Transmits `png` as image `id` and gives it a virtual placement `cols` by
/// `rows` cells — invisible until a placeholder cell points at it. Quiet (`q=2`)
/// so the terminal answers nothing the key reader would mistake for a key.
pub fn transmit(allocator: Allocator, id: u32, png: []const u8, cols: usize, rows: usize) !void {
    const bytes = try escape(allocator, id, png, cols, rows);
    defer allocator.free(bytes);
    try kitty.write(bytes);
}

/// The bytes `transmit` writes — split out so the framing can be checked
/// without a terminal.
pub fn escape(allocator: Allocator, id: u32, png: []const u8, cols: usize, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, png);

    var offset: usize = 0;
    var first = true;
    while (first or offset < encoded.len) {
        const end = @min(offset + chunk, encoded.len);
        const more = end < encoded.len;
        const control = if (first)
            try std.fmt.allocPrint(allocator, "\x1b_Ga=T,f=100,q=2,i={d},U=1,c={d},r={d},m={d};", .{ id, cols, rows, @intFromBool(more) })
        else
            try std.fmt.allocPrint(allocator, "\x1b_Gm={d};", .{@intFromBool(more)});
        defer allocator.free(control);
        first = false;
        try out.appendSlice(allocator, control);
        try out.appendSlice(allocator, encoded[offset..end]);
        try out.appendSlice(allocator, "\x1b\\");
        offset = end;
    }
    return out.toOwnedSlice(allocator);
}

/// Lays out the placeholder rows: one row per image row, the row's diacritic on
/// its first cell and the rest left plain, which is what lets a row of `cols`
/// cells carry a single diacritic — each cell after the first takes the column
/// to its left plus one.
pub fn placeholders(allocator: Allocator, id: u32, cols: usize, rows: usize, out: *std.ArrayList([]u8)) !void {
    const red: u8 = @intCast((id >> 16) & 0xff);
    const green: u8 = @intCast((id >> 8) & 0xff);
    const blue: u8 = @intCast(id & 0xff);
    var at: usize = 0;
    while (at < rows) : (at += 1) {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        const foreground = try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ red, green, blue });
        defer allocator.free(foreground);
        try line.appendSlice(allocator, foreground);
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            try line.appendSlice(allocator, cell);
            if (col == 0) {
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(row_diacritics[@min(at, row_diacritics.len - 1)], &buffer) catch 0;
                try line.appendSlice(allocator, buffer[0..n]);
            }
        }
        try line.appendSlice(allocator, "\x1b[39m");
        try out.append(allocator, try line.toOwnedSlice(allocator));
    }
}

test "a row of placeholders names the row once and colours the id" {
    const allocator = std.testing.allocator;
    var rows: std.ArrayList([]u8) = .empty;
    defer {
        for (rows.items) |line| allocator.free(line);
        rows.deinit(allocator);
    }
    try placeholders(allocator, 42, 2, 2, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("\x1b[38;2;0;0;42m" ++ cell ++ "\u{0305}" ++ cell ++ "\x1b[39m", rows.items[0]);
    try std.testing.expectEqualStrings("\x1b[38;2;0;0;42m" ++ cell ++ "\u{030D}" ++ cell ++ "\x1b[39m", rows.items[1]);
}

test "the escape frames the payload in chunks and closes with m=0" {
    const allocator = std.testing.allocator;
    // More than one chunk of PNG, so the first escape ends `m=1` and a later
    // one carries the `m=0`.
    const png = try allocator.alloc(u8, chunk * 3 / 4 + 1);
    defer allocator.free(png);
    @memset(png, 'a');
    const bytes = try escape(allocator, 7, png, 3, 2);
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b_Ga=T,f=100,q=2,i=7,U=1,c=3,r=2,m=1;"));
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b\\"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b_Gm=0;") != null);
}

test "one short picture is a single escape already ended" {
    const allocator = std.testing.allocator;
    const bytes = try escape(allocator, 7, "png", 1, 1);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b_Ga=T,f=100,q=2,i=7,U=1,c=1,r=1,m=0;"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b_Gm=0;") == null);
}