//! The world: one Ion-shaped value graph addressed by offset, held in a file
//! mapped `MAP_SHARED`.
//!
//! Values live in a flat byte region and name one another by byte offset
//! (`Ref`) from its start, never by pointer. The region is a file mapped
//! `MAP_SHARED`: the mapping *is* memory — a store to it is a load or store and
//! the kernel is the writer — and it neither moves nor dies with the process,
//! so an offset, and a slice into the region, is stable across processes. The
//! top level is a single Ion struct.
//!
//! Durability without `fsync`. A store that has landed is in the page cache,
//! and the kernel, which does not crash, writes it out, so a process killed at
//! any instruction sees it on reopen (`research/persistence.dj`). What that
//! leaves is a torn tail — a sequence of stores interrupted — and the update
//! discipline answers it:
//!
//!   * an existing struct field is updated in place, with one store of its
//!     `Ref`, so a reader sees the old value or the new one and never a mixture;
//!   * a size-changing update (adding or removing a field) builds a fresh node
//!     and publishes it with one `Ref` store, so no live node is ever rewritten
//!     in part.
//!
//! There is therefore no journal and no undo log. The remaining assumption is
//! that a store to an aligned word lands entirely or not at all — what the
//! hardware this targets does; write ordering across a power loss is not
//! addressed.
//!
//! Every allocation is framed with its size, so the region is a sequence of
//! blocks running from the header to `used`. `open` walks that sequence end to
//! end — validating the whole file, not only the part the graph reaches — and
//! then walks the graph; a fault at either step fails the open rather than
//! serving a half-read image. The image's header makes a reopen decode what
//! this build knows and refuse a version it does not.
//!
//! Bugs are excluded by three means, not by testing alone: a `@"struct"` and a
//! `symbol` have their own handle types (`StructRef`, `SymbolRef`), so an
//! operation cannot be applied to the wrong kind — it will not compile; a tag
//! is stored as a plain byte and decoded with `tagFromByte`, so a corrupt tag is
//! a returned error and never a `switch` on an invalid enum value; and
//! `validate` walks the reachable graph and reports any structural fault, so
//! the invariant is executable and can be asserted after every operation.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A byte offset from the start of the region. `none` is no value. A `Ref` is
/// only produced by the constructors below; a raw integer is not a `Ref`.
pub const Ref = u64;
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
    BadImage, // the region's length, magic, or version is not one this build knows
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

/// The region's first bytes are its header: four machine words that say what
/// the image is, so a reopen decodes what this build knows and refuses a version
/// it does not (`research/persistence.dj`). Node offsets begin past it.
const header_bytes = 32;
const magic: u64 = 0x574f524c445f5631; // "WORLD_V1", big-endian bytes
const version: u64 = 1;
const word_magic = 0;
const word_version = 1;
const word_used = 2;
const word_root = 3;

/// The flat byte region, seen as words. It is the file mapping; this type
/// neither allocates nor frees it, and its state lives in the header words
/// rather than in any Zig field, so it survives the process that wrote it.
const Loam = struct {
    words: []u64,

    fn base(self: *Loam) [*]u8 {
        return @ptrCast(self.words.ptr);
    }

    fn used(self: *Loam) usize {
        return @intCast(self.words[word_used]);
    }

    fn setUsed(self: *Loam, v: usize) void {
        self.words[word_used] = v;
    }

    fn root(self: *Loam) Ref {
        return self.words[word_root];
    }

    fn setRoot(self: *Loam, r: Ref) void {
        self.words[word_root] = r;
    }

    fn alloc(self: *Loam, n: usize) Fault!Ref {
        const data = (n + 7) & ~@as(usize, 7);
        const block = data + @sizeOf(u64); // the size word frames every allocation
        const off = self.used();
        const end = std.math.add(usize, off, block) catch return error.OutOfSpace;
        if (end > self.words.len * @sizeOf(u64)) return error.OutOfSpace;
        self.words[off / @sizeOf(u64)] = block;
        self.setUsed(end);
        return @intCast(off + @sizeOf(u64));
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
    io: std.Io,
    file: std.Io.File,
    mapping: []align(std.heap.page_size_min) u8,
    loam: Loam,

    /// Open the world at `path`, creating the file if it is absent. A file that
    /// holds no image is sized to `capacity`; a file that holds one is resumed
    /// at its own length, so `capacity` applies only to a fresh world. The file
    /// is mapped `MAP_SHARED`: the mapping is the world, and a store to it
    /// outlives the process that made it.
    pub fn open(gpa: Allocator, io: std.Io, path: []const u8, capacity: usize) !World {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
        errdefer file.close(io);

        const length = try file.length(io);
        const size = if (length == 0) blk: {
            try file.setLength(io, capacity);
            break :blk capacity;
        } else length;
        if (size < header_bytes or size % @sizeOf(u64) != 0) return error.BadImage;

        const mapping = try std.posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(mapping);

        var self = World{
            .gpa = gpa,
            .io = io,
            .file = file,
            .mapping = mapping,
            .loam = .{ .words = std.mem.bytesAsSlice(u64, mapping) },
        };
        try self.openImage();
        return self;
    }

    pub fn deinit(self: *World) void {
        std.posix.munmap(self.mapping);
        self.file.close(self.io);
        self.* = undefined;
    }

    /// A blank region carries no header: stamp one and make the empty root. A
    /// region that already holds an image must carry this build's magic and
    /// version, and its graph must pass the structural scan before it is served
    /// — skirting either would serve a graph this code cannot read.
    fn openImage(self: *World) !void {
        if (self.loam.words[word_magic] == 0) {
            self.loam.words[word_magic] = magic;
            self.loam.words[word_version] = version;
            self.loam.setUsed(header_bytes);
            self.loam.setRoot(none);
            self.setRoot(try self.makeStruct(&.{}));
            return;
        }
        if (self.loam.words[word_magic] != magic or self.loam.words[word_version] != version) {
            return error.BadImage;
        }
        try self.scan();
        try self.validate();
    }

    fn setRoot(self: *World, r: StructRef) void {
        self.loam.setRoot(@intFromEnum(r));
    }

    fn rootRef(self: *World) StructRef {
        return @enumFromInt(self.loam.root());
    }

    // ── liveness ────────────────────────────────────────────────────────────

    /// Whether `r` could name a node: in the used region and 8-aligned. It
    /// cannot tell a node start from the middle of another node's payload; that
    /// is what `validate` is for.
    pub fn alive(self: *World, r: Ref) bool {
        if (r == none or r < header_bytes + @sizeOf(u64)) return false;
        if (r % @sizeOf(u64) != 0) return false;
        const end = std.math.add(u64, r, @sizeOf(Node)) catch return false;
        return end <= self.loam.used();
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
        const end = std.math.add(u64, n.a, n.b) catch return null;
        if (end > self.loam.used()) return null;
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
        return self.get(self.rootRef(), name);
    }

    pub fn putField(self: *World, name: []const u8, value: Ref) Fault!void {
        self.setRoot(try self.put(self.rootRef(), name, value));
    }

    pub fn removeField(self: *World, name: []const u8) Fault!void {
        self.setRoot(try self.remove(self.rootRef(), name));
    }

    // ── the executable invariant ────────────────────────────────────────────

    /// Walk every block the allocator wrote, from the header to `used`, and
    /// report the first that is not well formed: a size word that is zero,
    /// unaligned, or runs past `used`. The blocks tile the region exactly, so
    /// this validates the whole file, not only the part the graph reaches.
    fn scan(self: *World) Fault!void {
        const used = self.loam.used();
        const total = self.loam.words.len * @sizeOf(u64);
        if (used > total or used < header_bytes or used % @sizeOf(u64) != 0) return error.BadSpan;
        var pos: usize = header_bytes;
        while (pos < used) {
            const size = self.loam.words[pos / @sizeOf(u64)];
            if (size == 0 or size % @sizeOf(u64) != 0) return error.BadSpan;
            const next = std.math.add(usize, pos, size) catch return error.BadSpan;
            if (next > used) return error.BadSpan;
            pos = next;
        }
    }

    /// Walk everything reachable from the root and report the first structural
    /// fault: a dangling handle, an unreadable tag, a payload past the region,
    /// a member whose name is not a symbol, or a graph too deep to walk.
    pub fn validate(self: *World) !void {
        var seen = std.AutoHashMap(Ref, void).init(self.gpa);
        defer seen.deinit();
        try self.walk(@intFromEnum(self.rootRef()), &seen, 0);
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
                try self.elems(n.a, n.b, @sizeOf(Ref));
                for (self.itemsOf(n)) |c| try self.walk(c, seen, depth + 1);
            },
            .@"struct" => {
                try self.elems(n.a, n.b, @sizeOf(Field));
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
        const end = std.math.add(u64, off, len) catch return error.BadSpan;
        if (end > self.loam.used()) return error.BadSpan;
    }

    /// A span of `count` elements `width` bytes each, the product made without
    /// overflowing on a corrupt count.
    fn elems(self: *World, off: u64, count: u64, comptime width: usize) Fault!void {
        const len = std.math.mul(u64, count, width) catch return error.BadSpan;
        return self.span(off, len);
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_io = std.testing.io;
const cap = 1 << 16;

/// A world in a fresh file under the test's tmp dir. It owns the file, the
/// path, and the tmp dir, so a test can reopen the same file after dropping the
/// world that wrote it.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    world: World,

    fn init(capacity: usize) !Scratch {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(test_io, &buf);
        const path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "world.bin" });
        errdefer testing.allocator.free(path);
        return .{ .tmp = tmp, .path = path, .world = try World.open(testing.allocator, test_io, path, capacity) };
    }

    fn deinit(self: *Scratch) void {
        self.world.deinit();
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

test "the root is a struct and starts empty" {
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
    try testing.expectEqual(Tag.@"struct", w.tagOf(@intFromEnum(w.rootRef())).?);
    try testing.expectEqual(@as(usize, 0), w.fields(w.rootRef()).len);
    try testing.expect(w.getField("anything") == null);
    try w.validate();
}

test "scalars round-trip" {
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
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
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
    try w.putField("n", try w.makeInt(1));
    const before = w.rootRef();
    try w.putField("n", try w.makeInt(2));
    try testing.expectEqual(before, w.rootRef());
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("n").?).?);
}

test "adding a field relocates the struct and is still found" {
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
    try w.putField("a", try w.makeInt(1));
    const first = w.rootRef();
    try w.putField("b", try w.makeInt(2));
    try testing.expect(w.rootRef() != first);
    try testing.expectEqual(@as(i64, 1), w.asInt(w.getField("a").?).?);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("b").?).?);
    try w.validate();
}

test "a nested struct and a list of refs" {
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
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
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
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
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
    try w.putField("a", try w.makeInt(1));
    try w.putField("b", try w.makeInt(2));
    try w.removeField("a");
    try testing.expect(w.getField("a") == null);
    try testing.expectEqual(@as(i64, 2), w.asInt(w.getField("b").?).?);
    try w.validate();
}

test "decimal and timestamp shapes" {
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
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
    var s = try Scratch.init(64);
    defer s.deinit();
    const w = &s.world;
    var i: u8 = 0;
    var filled = false;
    while (i < 20) : (i += 1) {
        const v = w.makeInt(i) catch |e| {
            try testing.expectEqual(Fault.OutOfSpace, e);
            filled = true;
            break;
        };
        w.putField("k", v) catch |e| {
            try testing.expectEqual(Fault.OutOfSpace, e);
            filled = true;
            break;
        };
    }
    try testing.expect(filled);
    try w.validate(); // whatever fit is still structurally sound
}

test "validate reports a forged handle instead of reading out of bounds" {
    var s = try Scratch.init(cap);
    defer s.deinit();
    const w = &s.world;
    // A Ref is an integer, so a caller can still mint one; the API cannot stop
    // that, but every reader now rejects it rather than dereferencing it.
    try testing.expect(w.tagOf(none) == null);
    try testing.expect(w.tagOf(999_999) == null); // aligned, past the region
    try testing.expect(w.tagOf(16) == null); // aligned and in the region, but no node
}

test "random operations agree with a reference model" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var s = try Scratch.init(1 << 22);
    defer s.deinit();
    const w = &s.world;

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
    try testing.expectEqual(model.count(), w.fields(w.rootRef()).len);
}

fn randomName(rand: std.Random, buf: []u8) []const u8 {
    const len = rand.intRangeAtMost(usize, 1, buf.len);
    for (buf[0..len]) |*b| b.* = 'a' + rand.intRangeAtMost(u8, 0, 2);
    return buf[0..len];
}

test "randomly built nested values validate" {
    var prng = std.Random.DefaultPrng.init(0xBADF00D);
    const rand = prng.random();
    var s = try Scratch.init(1 << 20);
    defer s.deinit();
    const w = &s.world;

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const v = try randomValue(w, rand, 0);
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
    var s = try Scratch.init(1 << 16);
    defer s.deinit();
    const w = &s.world;

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

test "a reopen reads the graph a killed writer left" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "world.bin" });
    defer testing.allocator.free(path);

    // Deliberately no deinit: the writer stops the way SIGKILL stops one, with
    // no chance to flush. MAP_SHARED stores are already in the page cache, so a
    // second open of the same file is exactly what a restarted process reads.
    {
        var first = try World.open(testing.allocator, test_io, path, cap);
        try first.putField("on", try first.makeBool(true));
        try first.putField("n", try first.makeInt(-42));
        try first.putField("name", try first.makeString("world"));
        try first.validate();
    }

    var w = try World.open(testing.allocator, test_io, path, 0); // capacity ignored: the file has length
    defer w.deinit();
    try testing.expectEqual(Tag.@"struct", w.tagOf(@intFromEnum(w.rootRef())).?);
    try testing.expect(w.asBool(w.getField("on").?).?);
    try testing.expectEqual(@as(i64, -42), w.asInt(w.getField("n").?).?);
    try testing.expectEqualStrings("world", w.text(w.getField("name").?).?);
    try w.validate();
}

test "a file that is not this image is refused, not read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "world.bin" });
    defer testing.allocator.free(path);

    var junk: [64]u8 = undefined;
    @memset(&junk, 0xde);
    try std.Io.Dir.cwd().writeFile(test_io, .{ .sub_path = path, .data = &junk });
    try testing.expectError(error.BadImage, World.open(testing.allocator, test_io, path, 0));
}

test "a block that runs past the region is rejected at open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "world.bin" });
    defer testing.allocator.free(path);

    var img: [64]u8 = undefined;
    @memset(&img, 0);
    const words = std.mem.bytesAsSlice(u64, img[0..]);
    words[word_magic] = magic;
    words[word_version] = version;
    words[word_used] = 1 << 40; // says the image is far larger than the file
    words[word_root] = none;
    try std.Io.Dir.cwd().writeFile(test_io, .{ .sub_path = path, .data = &img });
    try testing.expectError(error.BadSpan, World.open(testing.allocator, test_io, path, 0));
}