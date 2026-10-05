//! The world: one Ion-shaped value graph addressed by offset.
//!
//! Values live in a flat byte region and name one another by byte offset
//! (`Ref`) from its start, never by pointer — the region is reallocated as it
//! grows and is meant to be a mapped file later, so an address is not a stable
//! name. An offset is. The top level is a single `@"struct"`.
//!
//! Power-safe overwrite. This module *assumes* the backing region is power-safe
//! on overwrite: a store to an aligned location lands entirely or not at all,
//! even if power is lost mid-store. The whole update discipline follows:
//!
//!   * an existing struct field is updated in place, with one store of its
//!     `Ref`, so a reader sees the old value or the new one and never a mixture;
//!   * a size-changing update (adding or removing a field) builds a fresh node
//!     and publishes it with one `Ref` store, so no live node is ever rewritten
//!     in part.
//!
//! There is therefore no journal and no undo log, and no torn-tail recovery.
//! The assumption is not a property of any particular device — it is what a
//! word-sized aligned store does on the hardware this targets, and it is the
//! one thing the design gives up in exchange for that simplicity.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A byte offset from the start of the region. `none` is no value.
pub const Ref = u32;
pub const none: Ref = 0;

/// Ion's types, plus one. `ref` is the graph edge Ion's value-based model
/// cannot express, and the one kind this world adds to it.
pub const Tag = enum(u8) {
    nil, // Ion's `null`; with the nil flag, a typed null such as `null.int`
    bool,
    int,
    float,
    decimal,
    timestamp,
    string,
    symbol,
    blob,
    clob,
    list,
    @"struct",
    sexp,
    ref,
};

const nil_flag: u8 = 1 << 0; // this node is a null of its tag (a typed null)
const int_big: u8 = 1 << 1; // int payload is (offset, length) two's-complement BE
const dec_neg_zero: u8 = 1 << 2; // decimal is a negative zero
const ts_unknown_offset: u8 = 1 << 3; // timestamp's local offset is unknown

/// One value's fixed head. Variable data it points at lives later in the region
/// and is reached through `a`/`b`.
pub const Node = struct {
    tag: Tag,
    flags: u8 = 0,
    a: u64 = 0,
    b: u64 = 0,
};

/// A struct member: a name (a `symbol` node) and its value.
pub const Field = extern struct { name: Ref, value: Ref };

pub const Precision = enum(u8) { year, month, day, minute, second, fractional };

pub const Timestamp = extern struct {
    precision: Precision,
    year: i32,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    offset_minutes: i16 = 0,
    frac_off: Ref = none,
    frac_len: u32 = 0,
};

/// The flat byte region values are written into. Grown by doubling; `u64` words
/// give the 8-byte alignment every node and array needs.
const Loam = struct {
    gpa: Allocator,
    words: []u64 = &.{},
    used: usize = 8, // offset 0 is reserved as `none`

    fn deinit(self: *Loam) void {
        self.gpa.free(self.words);
        self.words = &.{};
    }

    fn base(self: *Loam) [*]u8 {
        return @ptrCast(self.words.ptr);
    }

    fn capacity(self: *Loam) usize {
        return self.words.len * 8;
    }

    fn alloc(self: *Loam, n: usize) !Ref {
        const aligned = (n + 7) & ~@as(usize, 7);
        const need = self.used + aligned;
        if (need > self.capacity()) try self.grow(need);
        const off = self.used;
        self.used = need;
        return @intCast(off);
    }

    fn grow(self: *Loam, need: usize) !void {
        var cap: usize = if (self.words.len == 0) 4096 else self.capacity();
        while (cap < need) cap *= 2;
        self.words = try self.gpa.realloc(self.words, cap / 8);
    }

    fn putBytes(self: *Loam, data: []const u8) !Ref {
        const off = try self.alloc(data.len);
        @memcpy(self.base()[off .. off + data.len], data);
        return off;
    }

    fn node(self: *Loam, r: Ref) *Node {
        return @ptrCast(@alignCast(self.base() + r));
    }

    fn bytes(self: *Loam, off: Ref, len: usize) []u8 {
        return self.base()[off .. off + len];
    }
};

pub const World = struct {
    gpa: Allocator,
    loam: Loam,
    root: Ref,

    pub fn init(gpa: Allocator) !World {
        var self = World{ .gpa = gpa, .loam = .{ .gpa = gpa }, .root = none };
        self.root = try self.makeStruct(&.{});
        return self;
    }

    pub fn deinit(self: *World) void {
        self.loam.deinit();
    }

    // ── construction ────────────────────────────────────────────────────────

    fn newNode(self: *World, node: Node) !Ref {
        const r = try self.loam.alloc(@sizeOf(Node));
        self.loam.node(r).* = node;
        return r;
    }

    fn makeBytes(self: *World, tag: Tag, v: []const u8) !Ref {
        const off = try self.loam.putBytes(v);
        return self.newNode(.{ .tag = tag, .a = off, .b = v.len });
    }

    fn makeSequence(self: *World, tag: Tag, children: []const Ref) !Ref {
        const off = if (children.len == 0) none else blk: {
            const len = children.len * @sizeOf(Ref);
            const o = try self.loam.alloc(len);
            @memcpy(self.loam.bytes(o, len), std.mem.sliceAsBytes(children));
            break :blk o;
        };
        return self.newNode(.{ .tag = tag, .a = off, .b = children.len });
    }

    pub fn makeNil(self: *World) !Ref {
        return self.newNode(.{ .tag = .nil, .flags = nil_flag });
    }

    /// A typed null: Ion's `null.int`, `null.list`, and the rest.
    pub fn makeTypedNull(self: *World, of: Tag) !Ref {
        return self.newNode(.{ .tag = of, .flags = nil_flag });
    }

    pub fn makeBool(self: *World, v: bool) !Ref {
        return self.newNode(.{ .tag = .bool, .a = @intFromBool(v) });
    }

    pub fn makeInt(self: *World, v: i64) !Ref {
        return self.newNode(.{ .tag = .int, .a = @bitCast(v) });
    }

    pub fn makeFloat(self: *World, v: f64) !Ref {
        return self.newNode(.{ .tag = .float, .a = @bitCast(v) });
    }

    pub fn makeDecimal(self: *World, coefficient: Ref, exponent: i32, negative_zero: bool) !Ref {
        return self.newNode(.{
            .tag = .decimal,
            .flags = if (negative_zero) dec_neg_zero else 0,
            .a = @as(u64, @bitCast(@as(i64, exponent))),
            .b = coefficient,
        });
    }

    pub fn makeString(self: *World, v: []const u8) !Ref {
        return self.makeBytes(.string, v);
    }

    pub fn makeSymbol(self: *World, v: []const u8) !Ref {
        return self.makeBytes(.symbol, v);
    }

    pub fn makeBlob(self: *World, v: []const u8) !Ref {
        return self.makeBytes(.blob, v);
    }

    pub fn makeClob(self: *World, v: []const u8) !Ref {
        return self.makeBytes(.clob, v);
    }

    pub fn makeList(self: *World, children: []const Ref) !Ref {
        return self.makeSequence(.list, children);
    }

    pub fn makeSexp(self: *World, children: []const Ref) !Ref {
        return self.makeSequence(.sexp, children);
    }

    pub fn makeStruct(self: *World, members: []const Field) !Ref {
        const off = if (members.len == 0) none else blk: {
            const len = members.len * @sizeOf(Field);
            const o = try self.loam.alloc(len);
            @memcpy(self.loam.bytes(o, len), std.mem.sliceAsBytes(members));
            break :blk o;
        };
        return self.newNode(.{ .tag = .@"struct", .a = off, .b = members.len });
    }

    pub fn makeRef(self: *World, to: Ref) !Ref {
        return self.newNode(.{ .tag = .ref, .a = to });
    }

    pub fn makeTimestamp(self: *World, ts: Timestamp) !Ref {
        const off = try self.loam.alloc(@sizeOf(Timestamp));
        const p: *Timestamp = @ptrCast(@alignCast(self.loam.base() + off));
        p.* = ts;
        return self.newNode(.{ .tag = .timestamp, .a = off });
    }

    // ── reading ─────────────────────────────────────────────────────────────

    pub fn tagOf(self: *World, r: Ref) Tag {
        return self.loam.node(r).tag;
    }

    pub fn isNull(self: *World, r: Ref) bool {
        return self.loam.node(r).flags & nil_flag != 0;
    }

    pub fn asBool(self: *World, r: Ref) bool {
        return self.loam.node(r).a != 0;
    }

    pub fn asInt(self: *World, r: Ref) ?i64 {
        const n = self.loam.node(r).*;
        if (n.tag != .int or n.flags & nil_flag != 0 or n.flags & int_big != 0) return null;
        return @bitCast(n.a);
    }

    pub fn asFloat(self: *World, r: Ref) ?f64 {
        const n = self.loam.node(r).*;
        if (n.tag != .float or n.flags & nil_flag != 0) return null;
        return @bitCast(n.a);
    }

    /// The bytes of a `string`, `symbol`, `blob`, or `clob`. Valid only until
    /// the next allocation, which may move the region.
    pub fn text(self: *World, r: Ref) ?[]const u8 {
        const n = self.loam.node(r).*;
        if (n.flags & nil_flag != 0) return null;
        return switch (n.tag) {
            .string, .symbol, .blob, .clob => self.loam.bytes(@intCast(n.a), @intCast(n.b)),
            else => null,
        };
    }

    /// The children of a `list` or `sexp`. Valid until the next allocation.
    pub fn items(self: *World, r: Ref) []const Ref {
        const n = self.loam.node(r).*;
        if (n.b == 0) return &.{};
        const p: [*]const Ref = @ptrCast(@alignCast(self.loam.base() + n.a));
        return p[0..@intCast(n.b)];
    }

    /// The members of a `@"struct"`. Valid until the next allocation.
    pub fn fields(self: *World, r: Ref) []const Field {
        const n = self.loam.node(r).*;
        if (n.b == 0) return &.{};
        const p: [*]const Field = @ptrCast(@alignCast(self.loam.base() + n.a));
        return p[0..@intCast(n.b)];
    }

    pub fn target(self: *World, r: Ref) Ref {
        return @intCast(self.loam.node(r).a);
    }

    // ── read/write on a struct ──────────────────────────────────────────────

    fn fieldSlot(self: *World, s: Ref, index: usize) *Field {
        const at = self.loam.node(s).a + index * @sizeOf(Field);
        return @ptrCast(@alignCast(self.loam.base() + at));
    }

    fn fieldIndex(self: *World, s: Ref, name: []const u8) ?usize {
        for (self.fields(s), 0..) |f, i| {
            if (std.mem.eql(u8, self.text(f.name).?, name)) return i;
        }
        return null;
    }

    pub fn get(self: *World, s: Ref, name: []const u8) ?Ref {
        const i = self.fieldIndex(s, name) orelse return null;
        return self.fields(s)[i].value;
    }

    /// Set `name` on `s`, returning the struct — the same `Ref` when the field
    /// exists, a fresh one when it does not, because adding a field is a new
    /// node published with one store.
    pub fn put(self: *World, s: Ref, name: []const u8, value: Ref) !Ref {
        if (self.fieldIndex(s, name)) |i| {
            self.fieldSlot(s, i).value = value; // one store; power-safe overwrite
            return s;
        }

        const n = self.loam.node(s).*;
        const name_ref = try self.makeSymbol(name);
        const count = n.b + 1;
        const len: usize = @intCast(count * @sizeOf(Field));
        const off = try self.loam.alloc(len);
        const dst = self.loam.bytes(off, len);
        const old_len: usize = @intCast(n.b * @sizeOf(Field));
        @memcpy(dst[0..old_len], self.loam.bytes(@intCast(n.a), old_len));
        const slot: *Field = @ptrCast(@alignCast(dst.ptr + old_len));
        slot.* = .{ .name = name_ref, .value = value };
        return self.newNode(.{ .tag = .@"struct", .a = off, .b = count });
    }

    pub fn remove(self: *World, s: Ref, name: []const u8) !Ref {
        const drop = self.fieldIndex(s, name) orelse return s;
        const n = self.loam.node(s).*;
        if (n.b <= 1) return self.newNode(.{ .tag = .@"struct" });

        const count = n.b - 1;
        const len: usize = @intCast(count * @sizeOf(Field));
        const off = try self.loam.alloc(len);
        const dst: [*]Field = @ptrCast(@alignCast(self.loam.base() + off));
        var w: usize = 0;
        for (0..@intCast(n.b)) |i| {
            if (i == drop) continue;
            dst[w] = self.fieldSlot(s, i).*;
            w += 1;
        }
        return self.newNode(.{ .tag = .@"struct", .a = off, .b = count });
    }

    // ── read/write on the world's root struct ───────────────────────────────

    pub fn getField(self: *World, name: []const u8) ?Ref {
        return self.get(self.root, name);
    }

    pub fn putField(self: *World, name: []const u8, value: Ref) !void {
        self.root = try self.put(self.root, name, value);
    }

    pub fn removeField(self: *World, name: []const u8) !void {
        self.root = try self.remove(self.root, name);
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the root is a struct and starts empty" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try testing.expectEqual(Tag.@"struct", w.tagOf(w.root));
    try testing.expectEqual(@as(usize, 0), w.fields(w.root).len);
    try testing.expect(w.getField("anything") == null);
}

test "scalars round-trip" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.putField("on", try w.makeBool(true));
    try w.putField("n", try w.makeInt(-42));
    try w.putField("x", try w.makeFloat(1.5));
    try w.putField("name", try w.makeString("world"));

    try testing.expect(w.asBool(w.getField("on").?));
    try testing.expectEqual(@as(i64, -42), w.asInt(w.getField("n").?).?);
    try testing.expectEqual(@as(f64, 1.5), w.asFloat(w.getField("x").?).?);
    try testing.expectEqualStrings("world", w.text(w.getField("name").?).?);
}

test "overwriting a field keeps the struct ref" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.putField("n", try w.makeInt(1));
    const before = w.root;
    try w.putField("n", try w.makeInt(2));
    try testing.expectEqual(before, w.root);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("n").?).?);
}

test "adding a field relocates the struct and is still found" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.putField("a", try w.makeInt(1));
    const first = w.root;
    try w.putField("b", try w.makeInt(2));
    try testing.expect(w.root != first);
    try testing.expectEqual(@as(i64, 1), w.asInt(w.getField("a").?).?);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("b").?).?);
}

test "a nested struct and a list of refs" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    const inner = try w.makeStruct(&.{});
    try w.putField("inner", inner);
    const three = try w.makeInt(3);
    const items = [_]Ref{ three, inner };
    try w.putField("xs", try w.makeList(&items));

    const xs = w.getField("xs").?;
    try testing.expectEqual(Tag.list, w.tagOf(xs));
    try testing.expectEqual(@as(usize, 2), w.items(xs).len);
    try testing.expectEqual(@as(i64, 3), w.asInt(w.items(xs)[0]).?);
    try testing.expectEqual(Tag.@"struct", w.tagOf(w.items(xs)[1]));
}

test "typed null and a reference" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.putField("maybe", try w.makeTypedNull(.int));
    const maybe = w.getField("maybe").?;
    try testing.expect(w.isNull(maybe));
    try testing.expectEqual(Tag.int, w.tagOf(maybe));
    try testing.expect(w.asInt(maybe) == null);

    const leaf = try w.makeString("leaf");
    try w.putField("edge", try w.makeRef(leaf));
    const edge = w.getField("edge").?;
    try testing.expectEqual(Tag.ref, w.tagOf(edge));
    try testing.expectEqualStrings("leaf", w.text(w.target(edge)).?);
}

test "removing a field" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    try w.putField("a", try w.makeInt(1));
    try w.putField("b", try w.makeInt(2));
    try w.removeField("a");
    try testing.expect(w.getField("a") == null);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("b").?).?);
}

test "decimal and timestamp shapes" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    const coeff = try w.makeInt(-123);
    try w.putField("price", try w.makeDecimal(coeff, -2, false));
    try testing.expectEqual(Tag.decimal, w.tagOf(w.getField("price").?));

    try w.putField("at", try w.makeTimestamp(.{
        .precision = .second,
        .year = 2026,
        .month = 10,
        .day = 5,
        .hour = 12,
    }));
    try testing.expectEqual(Tag.timestamp, w.tagOf(w.getField("at").?));
}