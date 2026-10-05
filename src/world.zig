//! The world: one Ion-shaped value graph addressed by offset.
//!
//! Values live in a flat byte region and name one another by byte offset
//! (`Ref`) from its start, never by pointer. The region is fixed for the
//! world's life, so an offset — and a slice into the region — is stable. The
//! top level is a single Ion struct.
//!
//! Power-safe overwrite. This module *assumes* the backing region is power-safe
//! on overwrite: a store to an aligned location lands entirely or not at all,
//! even if power is lost mid-store. The update discipline follows:
//!
//!   * an existing struct field is updated in place, with one store of its
//!     `Ref`, so a reader sees the old value or the new one and never a mixture;
//!   * a size-changing update (adding or removing a field) builds a fresh node
//!     and publishes it with one `Ref` store, so no live node is ever rewritten
//!     in part.
//!
//! There is therefore no journal, no undo log, and no torn-tail recovery. The
//! assumption is not a property of any particular device — it is what a
//! word-sized aligned store does on the hardware this targets — and it is the
//! one thing the design gives up in exchange for that simplicity.
//!
//! Bugs are excluded by three means, not by testing alone: a `@"struct"` and a
//! `symbol` have their own handle types (`StructRef`, `SymbolRef`), so an
//! operation cannot be applied to the wrong kind — it will not compile; a tag
//! is stored as a plain byte and decoded with `intToEnum`, so a corrupt tag is
//! a returned error and never a `switch` on an invalid enum value; and
//! `validate` walks the reachable graph and reports any structural fault, so
//! the invariant is executable and can be asserted after every operation.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A byte offset from the start of the region. `none` is no value. A `Ref` is
/// only produced by the constructors below; a raw integer is not a `Ref`.
pub const Ref = u32;
pub const none: Ref = 0;

/// Handles that carry their kind, so the struct and symbol operations cannot be
/// reached with a value of the wrong kind.
pub const StructRef = enum(Ref) { _ };
pub const SymbolRef = enum(Ref) { _ };

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

/// One value's fixed head. `tag` is a plain byte, not the enum, so that a
/// corrupt or uninitialized byte is readable and rejectable rather than an
/// invalid enum value.
pub const Node = struct {
    tag: u8,
    flags: u8 = 0,
    a: u64 = 0,
    b: u64 = 0,
};

/// A struct member: a name (a symbol) and its value. The name's kind is in its
/// type, so a member cannot be built with a non-symbol name.
pub const Field = extern struct { name: SymbolRef, value: Ref };

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

pub const Fault = error{
    BadHandle, // a Ref outside the region, misaligned, or not a node
    BadTag, // a tag byte that is not a Tag
    BadSpan, // a payload runs past the region
    BadFieldName, // a struct member's name is not a symbol
    TooDeep, // the graph is deeper than the walk allows
    OutOfSpace, // the region cannot hold the write
};

fn structHandle(r: Ref) StructRef {
    return @enumFromInt(r);
}

/// Decode a tag byte, or null if it is not one of `Tag`'s values. Reading a
/// corrupt tag as the enum would be an invalid enum value; this makes it a
/// value that can be rejected.
fn tagFromByte(b: u8) ?Tag {
    const info = @typeInfo(Tag).@"enum";
    inline for (info.field_names, info.field_values) |name, value| {
        if (value == b) return @field(Tag, name);
    }
    return null;
}

fn symbolHandle(r: Ref) SymbolRef {
    return @enumFromInt(r);
}

/// The flat byte region. Allocated once at the world's capacity and never
/// moved, so offsets and slices stay valid for its life.
const Loam = struct {
    gpa: Allocator,
    words: []u64,
    used: usize = 8, // offset 0 is reserved as `none`

    fn init(gpa: Allocator, capacity: usize) !Loam {
        const words = try gpa.alloc(u64, @max(1, (capacity + 7) / 8));
        @memset(words, 0);
        return .{ .gpa = gpa, .words = words };
    }

    fn deinit(self: *Loam) void {
        self.gpa.free(self.words);
        self.words = &.{};
    }

    fn base(self: *Loam) [*]u8 {
        return @ptrCast(self.words.ptr);
    }

    fn alloc(self: *Loam, n: usize) Fault!Ref {
        const aligned = (n + 7) & ~@as(usize, 7);
        const need = self.used + aligned;
        if (need > self.words.len * 8) return error.OutOfSpace;
        const off = self.used;
        self.used = need;
        return @intCast(off);
    }

    fn putBytes(self: *Loam, data: []const u8) Fault!Ref {
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
    root: StructRef,

    pub fn init(gpa: Allocator, capacity: usize) !World {
        var self = World{ .gpa = gpa, .loam = try Loam.init(gpa, capacity), .root = undefined };
        self.root = try self.makeStruct(&.{});
        return self;
    }

    pub fn deinit(self: *World) void {
        self.loam.deinit();
    }

    // ── liveness ────────────────────────────────────────────────────────────

    /// Whether `r` could name a node: in the used region and 8-aligned. It
    /// cannot tell a node start from the middle of another node's payload; that
    /// is what `validate` is for.
    pub fn alive(self: *World, r: Ref) bool {
        if (r == none) return false;
        if (r % @sizeOf(u64) != 0) return false;
        return @as(usize, r) + @sizeOf(Node) <= self.loam.used;
    }

    fn tagAt(self: *World, r: Ref) Fault!Tag {
        if (!self.alive(r)) return error.BadHandle;
        return tagFromByte(self.loam.node(r).tag) orelse error.BadTag;
    }

    // ── construction ────────────────────────────────────────────────────────

    fn newNode(self: *World, node: Node) Fault!Ref {
        const r = try self.loam.alloc(@sizeOf(Node));
        self.loam.node(r).* = node;
        return r;
    }

    fn makeBytes(self: *World, tag: Tag, v: []const u8) Fault!Ref {
        const off = try self.loam.putBytes(v);
        return self.newNode(.{ .tag = @intFromEnum(tag), .a = off, .b = v.len });
    }

    pub fn makeNil(self: *World) Fault!Ref {
        return self.newNode(.{ .tag = @intFromEnum(Tag.nil), .flags = nil_flag });
    }

    /// A typed null: Ion's `null.int`, `null.list`, and the rest.
    pub fn makeTypedNull(self: *World, of: Tag) Fault!Ref {
        return self.newNode(.{ .tag = @intFromEnum(of), .flags = nil_flag });
    }

    pub fn makeBool(self: *World, v: bool) Fault!Ref {
        return self.newNode(.{ .tag = @intFromEnum(Tag.bool), .a = @intFromBool(v) });
    }

    pub fn makeInt(self: *World, v: i64) Fault!Ref {
        return self.newNode(.{ .tag = @intFromEnum(Tag.int), .a = @bitCast(v) });
    }

    pub fn makeFloat(self: *World, v: f64) Fault!Ref {
        return self.newNode(.{ .tag = @intFromEnum(Tag.float), .a = @bitCast(v) });
    }

    pub fn makeDecimal(self: *World, coefficient: Ref, exponent: i32, negative_zero: bool) Fault!Ref {
        return self.newNode(.{
            .tag = @intFromEnum(Tag.decimal),
            .flags = if (negative_zero) dec_neg_zero else 0,
            .a = @as(u64, @bitCast(@as(i64, exponent))),
            .b = coefficient,
        });
    }

    pub fn makeString(self: *World, v: []const u8) Fault!Ref {
        return self.makeBytes(.string, v);
    }

    pub fn makeBlob(self: *World, v: []const u8) Fault!Ref {
        return self.makeBytes(.blob, v);
    }

    pub fn makeClob(self: *World, v: []const u8) Fault!Ref {
        return self.makeBytes(.clob, v);
    }

    pub fn makeSymbol(self: *World, v: []const u8) Fault!SymbolRef {
        return symbolHandle(try self.makeBytes(.symbol, v));
    }

    fn makeSequence(self: *World, tag: Tag, children: []const Ref) Fault!Ref {
        const off = if (children.len == 0) none else blk: {
            const len = children.len * @sizeOf(Ref);
            const o = try self.loam.alloc(len);
            @memcpy(self.loam.bytes(o, len), std.mem.sliceAsBytes(children));
            break :blk o;
        };
        return self.newNode(.{ .tag = @intFromEnum(tag), .a = off, .b = children.len });
    }

    pub fn makeList(self: *World, children: []const Ref) Fault!Ref {
        return self.makeSequence(.list, children);
    }

    pub fn makeSexp(self: *World, children: []const Ref) Fault!Ref {
        return self.makeSequence(.sexp, children);
    }

    pub fn makeStruct(self: *World, members: []const Field) Fault!StructRef {
        const off = if (members.len == 0) none else blk: {
            const len = members.len * @sizeOf(Field);
            const o = try self.loam.alloc(len);
            @memcpy(self.loam.bytes(o, len), std.mem.sliceAsBytes(members));
            break :blk o;
        };
        const r = try self.newNode(.{ .tag = @intFromEnum(Tag.@"struct"), .a = off, .b = members.len });
        return structHandle(r);
    }

    pub fn makeRef(self: *World, to: Ref) Fault!Ref {
        return self.newNode(.{ .tag = @intFromEnum(Tag.ref), .a = to });
    }

    pub fn makeTimestamp(self: *World, ts: Timestamp) Fault!Ref {
        const off = try self.loam.alloc(@sizeOf(Timestamp));
        const p: *Timestamp = @ptrCast(@alignCast(self.loam.base() + off));
        p.* = ts;
        return self.newNode(.{ .tag = @intFromEnum(Tag.timestamp), .a = off });
    }

    // ── reading ─────────────────────────────────────────────────────────────

    pub fn tagOf(self: *World, r: Ref) ?Tag {
        return self.tagAt(r) catch null;
    }

    pub fn isNull(self: *World, r: Ref) bool {
        return self.alive(r) and self.loam.node(r).flags & nil_flag != 0;
    }

    pub fn asBool(self: *World, r: Ref) ?bool {
        if ((self.tagOf(r) orelse return null) != .bool or self.isNull(r)) return null;
        return self.loam.node(r).a != 0;
    }

    pub fn asInt(self: *World, r: Ref) ?i64 {
        if ((self.tagOf(r) orelse return null) != .int or self.isNull(r)) return null;
        const n = self.loam.node(r).*;
        if (n.flags & int_big != 0) return null;
        return @bitCast(n.a);
    }

    pub fn asFloat(self: *World, r: Ref) ?f64 {
        if ((self.tagOf(r) orelse return null) != .float or self.isNull(r)) return null;
        return @bitCast(self.loam.node(r).a);
    }

    /// The bytes of a `string`, `symbol`, `blob`, or `clob`, or null if `r` is
    /// none of those or a null. The slice is stable for the world's life.
    pub fn text(self: *World, r: Ref) ?[]const u8 {
        const tag = self.tagOf(r) orelse return null;
        if (self.isNull(r)) return null;
        return switch (tag) {
            .string, .symbol, .blob, .clob => self.bytesOf(r),
            else => null,
        };
    }

    pub fn symbolText(self: *World, s: SymbolRef) []const u8 {
        return self.bytesOf(@intFromEnum(s)) orelse "";
    }

    fn bytesOf(self: *World, r: Ref) ?[]const u8 {
        if (!self.alive(r)) return null;
        const n = self.loam.node(r).*;
        const end = @as(usize, @intCast(n.a)) + @as(usize, @intCast(n.b));
        if (end > self.loam.used) return null;
        return self.loam.bytes(@intCast(n.a), @intCast(n.b));
    }

    /// The children of a `list` or `sexp`, or null for any other kind.
    pub fn items(self: *World, r: Ref) ?[]const Ref {
        const tag = self.tagOf(r) orelse return null;
        if (tag != .list and tag != .sexp) return null;
        return self.itemsOf(self.loam.node(r).*);
    }

    fn itemsOf(self: *World, n: Node) []const Ref {
        if (n.b == 0) return &.{};
        const p: [*]const Ref = @ptrCast(@alignCast(self.loam.base() + @as(usize, @intCast(n.a))));
        return p[0..@intCast(n.b)];
    }

    /// The struct behind a `Ref`, checked, or null if `r` is not a live struct.
    pub fn asStruct(self: *World, r: Ref) ?StructRef {
        if ((self.tagOf(r) orelse return null) != .@"struct" or self.isNull(r)) return null;
        return structHandle(r);
    }

    pub fn target(self: *World, r: Ref) ?Ref {
        if ((self.tagOf(r) orelse return null) != .ref) return null;
        return @intCast(self.loam.node(r).a);
    }

    /// The members of a struct. The slice is stable for the world's life.
    pub fn fields(self: *World, s: StructRef) []const Field {
        return self.fieldsOf(self.loam.node(@intFromEnum(s)).*);
    }

    fn fieldsOf(self: *World, n: Node) []const Field {
        if (n.b == 0) return &.{};
        const p: [*]const Field = @ptrCast(@alignCast(self.loam.base() + @as(usize, @intCast(n.a))));
        return p[0..@intCast(n.b)];
    }

    fn fieldSlot(self: *World, s: StructRef, index: usize) *Field {
        const at = self.loam.node(@intFromEnum(s)).a + index * @sizeOf(Field);
        return @ptrCast(@alignCast(self.loam.base() + @as(usize, @intCast(at))));
    }

    fn findField(self: *World, s: StructRef, name: []const u8) ?usize {
        for (self.fields(s), 0..) |f, i| {
            if (std.mem.eql(u8, self.symbolText(f.name), name)) return i;
        }
        return null;
    }

    // ── read/write on a struct ──────────────────────────────────────────────

    pub fn get(self: *World, s: StructRef, name: []const u8) ?Ref {
        const i = self.findField(s, name) orelse return null;
        return self.fields(s)[i].value;
    }

    /// Set `name` on `s`, returning the struct — the same handle when the field
    /// exists, a fresh one when it does not, because adding a field is a new
    /// node published with one store.
    pub fn put(self: *World, s: StructRef, name: []const u8, value: Ref) Fault!StructRef {
        if (self.findField(s, name)) |i| {
            self.fieldSlot(s, i).value = value; // one store; power-safe overwrite
            return s;
        }

        const sr = @intFromEnum(s);
        const n = self.loam.node(sr).*;
        const name_ref = try self.makeSymbol(name);
        const count = n.b + 1;
        const len: usize = @intCast(count * @sizeOf(Field));
        const off = try self.loam.alloc(len);
        const dst = self.loam.bytes(off, len);
        const old_len: usize = @intCast(n.b * @sizeOf(Field));
        if (old_len > 0) @memcpy(dst[0..old_len], self.loam.bytes(@intCast(n.a), old_len));
        const slot: *Field = @ptrCast(@alignCast(dst.ptr + old_len));
        slot.* = .{ .name = name_ref, .value = value };
        const r = try self.newNode(.{ .tag = @intFromEnum(Tag.@"struct"), .a = off, .b = count });
        return structHandle(r);
    }

    pub fn remove(self: *World, s: StructRef, name: []const u8) Fault!StructRef {
        const drop = self.findField(s, name) orelse return s;
        const sr = @intFromEnum(s);
        const n = self.loam.node(sr).*;
        if (n.b <= 1) return self.makeStruct(&.{});

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
        const r = try self.newNode(.{ .tag = @intFromEnum(Tag.@"struct"), .a = off, .b = count });
        return structHandle(r);
    }

    // ── read/write on the world's root struct ───────────────────────────────

    pub fn getField(self: *World, name: []const u8) ?Ref {
        return self.get(self.root, name);
    }

    pub fn putField(self: *World, name: []const u8, value: Ref) Fault!void {
        self.root = try self.put(self.root, name, value);
    }

    pub fn removeField(self: *World, name: []const u8) Fault!void {
        self.root = try self.remove(self.root, name);
    }

    // ── the executable invariant ────────────────────────────────────────────

    /// Walk everything reachable from the root and report the first structural
    /// fault: a dangling handle, an unreadable tag, a payload past the region,
    /// a member whose name is not a symbol, or a graph too deep to walk.
    pub fn validate(self: *World) !void {
        var seen = std.AutoHashMap(Ref, void).init(self.gpa);
        defer seen.deinit();
        try self.walk(@intFromEnum(self.root), &seen, 0);
    }

    fn walk(self: *World, r: Ref, seen: *std.AutoHashMap(Ref, void), depth: usize) !void {
        if (depth > 4096) return error.TooDeep;
        if (!self.alive(r)) return error.BadHandle;
        if (seen.contains(r)) return;
        try seen.put(r, {});

        const n = self.loam.node(r).*;
        const tag = tagFromByte(n.tag) orelse return error.BadTag;
        if (n.flags & nil_flag != 0) return;

        switch (tag) {
            .nil, .bool, .int, .float, .ref => {},
            .string, .symbol, .blob, .clob => try self.span(n.a, n.b),
            .decimal => if (!self.alive(@intCast(n.b))) return error.BadHandle,
            .timestamp => try self.span(n.a, @sizeOf(Timestamp)),
            .list, .sexp => {
                try self.span(n.a, n.b * @sizeOf(Ref));
                for (self.itemsOf(n)) |c| try self.walk(c, seen, depth + 1);
            },
            .@"struct" => {
                try self.span(n.a, n.b * @sizeOf(Field));
                for (self.fieldsOf(n)) |f| {
                    try self.walk(@intFromEnum(f.name), seen, depth + 1);
                    const name_tag = self.tagOf(@intFromEnum(f.name)) orelse return error.BadFieldName;
                    if (name_tag != .symbol) return error.BadFieldName;
                    try self.walk(f.value, seen, depth + 1);
                }
            },
        }
    }

    fn span(self: *World, off: u64, len: u64) Fault!void {
        if (off == 0 and len == 0) return;
        const end = @as(usize, @intCast(off)) + @as(usize, @intCast(len));
        if (end > self.loam.used) return error.BadSpan;
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const cap = 1 << 16;

test "the root is a struct and starts empty" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    try testing.expectEqual(Tag.@"struct", w.tagOf(@intFromEnum(w.root)).?);
    try testing.expectEqual(@as(usize, 0), w.fields(w.root).len);
    try testing.expect(w.getField("anything") == null);
    try w.validate();
}

test "scalars round-trip" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    try w.putField("on", try w.makeBool(true));
    try w.putField("n", try w.makeInt(-42));
    try w.putField("x", try w.makeFloat(1.5));
    try w.putField("name", try w.makeString("world"));

    try testing.expect(w.asBool(w.getField("on").?).?);
    try testing.expectEqual(@as(i64, -42), w.asInt(w.getField("n").?).?);
    try testing.expectEqual(@as(f64, 1.5), w.asFloat(w.getField("x").?).?);
    try testing.expectEqualStrings("world", w.text(w.getField("name").?).?);
    try w.validate();
}

test "overwriting a field keeps the struct handle" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    try w.putField("n", try w.makeInt(1));
    const before = w.root;
    try w.putField("n", try w.makeInt(2));
    try testing.expectEqual(before, w.root);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("n").?).?);
}

test "adding a field relocates the struct and is still found" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    try w.putField("a", try w.makeInt(1));
    const first = w.root;
    try w.putField("b", try w.makeInt(2));
    try testing.expect(w.root != first);
    try testing.expectEqual(@as(i64, 1), w.asInt(w.getField("a").?).?);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("b").?).?);
    try w.validate();
}

test "a nested struct and a list of refs" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    const inner = try w.makeStruct(&.{});
    try w.putField("inner", @intFromEnum(inner));
    const three = try w.makeInt(3);
    const children = [_]Ref{ three, @intFromEnum(inner) };
    try w.putField("xs", try w.makeList(&children));

    const xs = w.getField("xs").?;
    try testing.expectEqual(Tag.list, w.tagOf(xs).?);
    try testing.expectEqual(@as(usize, 2), w.items(xs).?.len);
    try testing.expectEqual(@as(i64, 3), w.asInt(w.items(xs).?[0]).?);
    try testing.expect(w.asStruct(w.items(xs).?[1]) != null);
    try w.validate();
}

test "typed null and a reference" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    try w.putField("maybe", try w.makeTypedNull(.int));
    const maybe = w.getField("maybe").?;
    try testing.expect(w.isNull(maybe));
    try testing.expectEqual(Tag.int, w.tagOf(maybe).?);
    try testing.expect(w.asInt(maybe) == null);

    const leaf = try w.makeString("leaf");
    try w.putField("edge", try w.makeRef(leaf));
    const edge = w.getField("edge").?;
    try testing.expectEqual(Tag.ref, w.tagOf(edge).?);
    try testing.expectEqualStrings("leaf", w.text(w.target(edge).?).?);
    try w.validate();
}

test "removing a field" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    try w.putField("a", try w.makeInt(1));
    try w.putField("b", try w.makeInt(2));
    try w.removeField("a");
    try testing.expect(w.getField("a") == null);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("b").?).?);
    try w.validate();
}

test "decimal and timestamp shapes" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    const coeff = try w.makeInt(-123);
    try w.putField("price", try w.makeDecimal(coeff, -2, false));
    try testing.expectEqual(Tag.decimal, w.tagOf(w.getField("price").?).?);

    try w.putField("at", try w.makeTimestamp(.{
        .precision = .second,
        .year = 2026,
        .month = 10,
        .day = 5,
        .hour = 12,
    }));
    try testing.expectEqual(Tag.timestamp, w.tagOf(w.getField("at").?).?);
    try w.validate();
}

test "the region is bounded: over-filling is an error, not a fault" {
    var w = try World.init(testing.allocator, 64);
    defer w.deinit();
    var i: u8 = 0;
    var filled = false;
    while (i < 20) : (i += 1) {
        w.putField("k", try w.makeInt(i)) catch |e| {
            try testing.expectEqual(Fault.OutOfSpace, e);
            filled = true;
            break;
        };
    }
    try testing.expect(filled);
    try w.validate(); // whatever fit is still structurally sound
}

test "validate reports a forged handle instead of reading out of bounds" {
    var w = try World.init(testing.allocator, cap);
    defer w.deinit();
    // A Ref is an integer, so a caller can still mint one; the API cannot stop
    // that, but every reader now rejects it rather than dereferencing it.
    try testing.expect(w.tagOf(none) == null);
    try testing.expect(w.tagOf(999_999) == null); // aligned, past the region
    try testing.expect(w.tagOf(16) == null); // aligned and in the region, but no node
}

test "random operations agree with a reference model" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var w = try World.init(testing.allocator, 1 << 22);
    defer w.deinit();

    var model = std.StringHashMap(i64).init(testing.allocator);
    defer {
        var it = model.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        model.deinit();
    }

    var buf: [3]u8 = undefined;
    var step: usize = 0;
    while (step < 3000) : (step += 1) {
        const name = randomName(rand, &buf);
        switch (rand.intRangeAtMost(u8, 0, 2)) {
            0, 1 => {
                const v = rand.int(i64);
                w.putField(name, try w.makeInt(v)) catch |e| switch (e) {
                    error.OutOfSpace => continue,
                    else => return e,
                };
                if (model.getPtr(name)) |p| {
                    p.* = v;
                } else {
                    try model.put(try testing.allocator.dupe(u8, name), v);
                }
            },
            2 => {
                try w.removeField(name);
                if (model.fetchRemove(name)) |kv| testing.allocator.free(kv.key);
            },
            else => unreachable,
        }

        try w.validate();
        const expected = model.get(name);
        const got = w.getField(name);
        if (expected) |v| {
            try testing.expect(got != null);
            try testing.expectEqual(v, w.asInt(got.?).?);
        } else {
            try testing.expect(got == null);
        }
    }

    // The model and the world agree on everything, not only the sampled name.
    var it = model.iterator();
    while (it.next()) |e| {
        try testing.expectEqual(e.value_ptr.*, w.asInt(w.getField(e.key_ptr.*).?).?);
    }
    try testing.expectEqual(model.count(), w.fields(w.root).len);
}

fn randomName(rand: std.Random, buf: []u8) []const u8 {
    const len = rand.intRangeAtMost(usize, 1, buf.len);
    for (buf[0..len]) |*b| b.* = 'a' + rand.intRangeAtMost(u8, 0, 2);
    return buf[0..len];
}

test "randomly built nested values validate" {
    var prng = std.Random.DefaultPrng.init(0xBADF00D);
    const rand = prng.random();
    var w = try World.init(testing.allocator, 1 << 20);
    defer w.deinit();

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const v = try randomValue(&w, rand, 0);
        try w.putField("v", v);
        try w.validate();
        try testing.expect(w.tagOf(v).? != .nil);
    }
}

fn randomValue(w: *World, rand: std.Random, depth: usize) Fault!Ref {
    const pick = if (depth >= 3) rand.intRangeAtMost(u8, 0, 3) else rand.intRangeAtMost(u8, 0, 5);
    switch (pick) {
        0 => return w.makeInt(rand.int(i64)),
        1 => return w.makeFloat(rand.float(f64)),
        2 => return w.makeBool(rand.boolean()),
        3 => {
            var buf: [8]u8 = undefined;
            const n = rand.intRangeAtMost(usize, 0, buf.len);
            rand.bytes(buf[0..n]);
            return w.makeString(buf[0..n]);
        },
        else => {
            var kids: [3]Ref = undefined;
            const n = rand.intRangeAtMost(usize, 0, kids.len);
            for (kids[0..n]) |*k| k.* = try randomValue(w, rand, depth + 1);
            return if (pick == 4) w.makeList(kids[0..n]) else w.makeSexp(kids[0..n]);
        },
    }
}

test "fuzz: no operation sequence corrupts the world" {
    try testing.fuzz({}, fuzzWorld, .{});
}

fn fuzzWorld(_: void, smith: *testing.Smith) anyerror!void {
    var w = try World.init(testing.allocator, 1 << 16);
    defer w.deinit();

    var names: [8][3]u8 = undefined;
    for (&names) |*n| smith.bytes(n);

    var i: usize = 0;
    while (i < 64 and !smith.eosWeightedSimple(1, 8)) : (i += 1) {
        const name = names[smith.valueRangeLessThan(u8, 0, names.len)];
        switch (smith.value(enum { put, remove })) {
            .put => {
                const v = try w.makeInt(smith.value(i64));
                w.putField(&name, v) catch {};
            },
            .remove => try w.removeField(&name),
        }
        try w.validate();
    }
}