//! A JSON encoder driven by per-type configuration.
//!
//! Encoding a type means walking its fields and writing the JSON the wire
//! format needs. What that shape is comes from data, not from a method written
//! per type: a type declares
//!
//!     pub const json = .{ ... };
//!
//! and `encode` reads it. Everything the DeepSeek endpoints need is expressible
//! this way except three genuinely irregular shapes — a content that is a
//! string or an array, stop sequences that are a string or an array, and a tool
//! choice that is a string or an object — and those name a function instead:
//!
//!     pub const json = .{ .encode = encodeContent };
//!
//! The vocabulary, all optional:
//!
//!   * `.fields` — per-field rules, keyed by field name:
//!       * `.key = "wire_name"` — the JSON key, when it differs from the field
//!         name.
//!       * `.skip = true` — never written. For fields that carry state the
//!         wire format has no place for.
//!       * `.skip_if_null = false` — write an optional field even when it is
//!         null. Nulls are skipped by default.
//!       * `.skip_if_empty = true` — skip an empty string or an empty slice.
//!       * `.skip_if_false = true` — skip a `false` flag.
//!   * `.raw = true` — write the string as pre-encoded JSON rather than as a
//!     JSON string. `Raw` declares this; prefer it to setting it by hand.
//!   * `.bare = true` — write the value itself rather than as an object; for a
//!     union, write the active variant's payload with no tag.
//!   * `.tag_key = "type"` — for an enum, write `{"type":"variant"}` instead of
//!     a bare string; for a union, write the variant name under this key (the
//!     tag) instead of an object keyed by the variant name.
//!   * `.fields` on a union names each variant's rule:
//!       * `.flatten = true` — write the payload's fields inside the tag's
//!         object instead of nesting them under the variant name.
//!       * `.bare = true` — write the payload as the whole value, with no tag
//!         and no object, for a payload that carries its own discriminator.
//!       * `.key = "wire_name"` — override the variant name: the tag's value,
//!         and, when the payload is not flattened, its key as well.
//!   * `.encode = someFunction` — take over entirely. The function takes
//!     `(e: *Encoder, value: T)` — both concrete, so nothing here is untyped.
//!
//! Fields are written in declaration order, which is the order the wire format
//! wants, and a field's own name is its JSON key unless a rule renames it.
//!
//! Strings are written verbatim apart from the characters JSON requires to be
//! escaped — `"`, `\` and U+0000 to U+001F — so a string that is not UTF-8 is
//! what makes the output invalid JSON, not what this encoder does with it. The
//! bytes go through as they are, which is where this differs from `std.json`,
//! that writes them as an array of numbers.

const std = @import("std");
const Io = std.Io;

pub const Error = Io.Writer.Error || error{
    /// The value nests deeper than this encoder writes.
    DepthTooDeep,
    /// A float JSON cannot carry. `null` is not the same value, so this is
    /// reported rather than written.
    NotFinite,
};

/// The deepest object or array this encoder writes before giving up. The API's
/// payloads are nowhere near it; it bounds the comma bookkeeping.
pub const max_depth = 64;

/// Writes JSON: the writer, and the per-level state that decides where the
/// separators go.
pub const Encoder = struct {
    out: *Io.Writer,
    /// Per level: whether a separator is needed before the next element, and
    /// whether the next value follows a key.
    comma: [max_depth]bool = @splat(false),
    after_key: [max_depth]bool = @splat(false),
    depth: usize = 0,

    pub fn init(out: *Io.Writer) Encoder {
        return .{ .out = out };
    }

    /// Encodes `value` as a JSON document.
    pub fn write(self: *Encoder, value: anytype) Error!void {
        return encode(self, value);
    }

    /// Writes the separator a level owes before its next member, and records
    /// that it now has one. `after_key` is the caller's to set: a value
    /// following a key is not a member yet, an element is.
    fn separate(self: *Encoder, level: usize) Error!void {
        if (self.comma[level] and !self.after_key[level]) try self.out.writeByte(',');
        self.comma[level] = true;
    }

    /// Writes the separator an element at the current level needs.
    fn element(self: *Encoder) Error!void {
        if (self.depth == 0) return;
        const level = self.depth - 1;
        try self.separate(level);
        self.after_key[level] = false;
    }

    fn push(self: *Encoder) Error!void {
        if (self.depth == max_depth) return error.DepthTooDeep;
        self.comma[self.depth] = false;
        self.after_key[self.depth] = false;
        self.depth += 1;
    }

    fn pop(self: *Encoder) void {
        self.depth -= 1;
    }

    pub fn beginObject(self: *Encoder) Error!void {
        try self.element();
        try self.push();
        try self.out.writeByte('{');
    }

    pub fn endObject(self: *Encoder) Error!void {
        self.pop();
        try self.out.writeByte('}');
    }

    pub fn beginArray(self: *Encoder) Error!void {
        try self.element();
        try self.push();
        try self.out.writeByte('[');
    }

    pub fn endArray(self: *Encoder) Error!void {
        self.pop();
        try self.out.writeByte(']');
    }

    /// Writes an object key. The following value must be written next.
    pub fn key(self: *Encoder, name: []const u8) Error!void {
        const level = self.depth - 1;
        try self.separate(level);
        self.after_key[level] = true;
        try writeString(self.out, name);
        try self.out.writeByte(':');
    }

    pub fn string(self: *Encoder, value: []const u8) Error!void {
        try self.element();
        try writeString(self.out, value);
    }

    /// Writes `encoded` as-is. Use `Raw` instead of calling this directly.
    pub fn raw(self: *Encoder, encoded: []const u8) Error!void {
        try self.element();
        try self.out.writeAll(encoded);
    }

    pub fn nullValue(self: *Encoder) Error!void {
        try self.element();
        try self.out.writeAll("null");
    }

    pub fn boolean(self: *Encoder, value: bool) Error!void {
        try self.element();
        try self.out.writeAll(if (value) "true" else "false");
    }

    pub fn integer(self: *Encoder, value: anytype) Error!void {
        try self.element();
        try self.out.print("{d}", .{value});
    }

    pub fn float(self: *Encoder, value: f64) Error!void {
        try self.element();
        if (!std.math.isFinite(value)) return error.NotFinite;
        try self.out.print("{d}", .{value});
    }
};

/// A string that is already JSON, written verbatim. Use it for schema text and
/// anything else whose JSON form the caller builds itself.
pub const Raw = struct {
    text: []const u8,

    pub const json = .{ .raw = true };
};

/// Encodes `value` with a fresh encoder.
pub fn encode(e: *Encoder, value: anytype) Error!void {
    const T = @TypeOf(value);

    if (comptime hasCustomEncode(T)) return @field(T, "json").encode(e, value);
    if (comptime isRaw(T)) return e.raw(value.text);

    switch (@typeInfo(T)) {
        .optional => {
            if (value) |inner| return encode(e, inner);
            return e.nullValue();
        },
        .bool => return e.boolean(value),
        .int, .comptime_int => return e.integer(value),
        .float, .comptime_float => return e.float(@floatCast(value)),
        .@"enum" => {
            if (comptime tagKey(T)) |key| {
                try e.beginObject();
                try e.key(key);
                try e.string(@tagName(value));
                return e.endObject();
            }
            return e.string(@tagName(value));
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) return e.string(value);
                return encodeSlice(e, value);
            },
            .one => return encode(e, value.*),
            else => @compileError("json: cannot encode " ++ @typeName(T)),
        },
        .array => |info| {
            if (info.child == u8) return e.string(&value);
            return encodeSlice(e, &value);
        },
        .@"struct" => |info| {
            if (comptime isBare(T)) {
                if (info.field_names.len != 1) {
                    @compileError("json: a bare struct needs exactly one field");
                }
                return encode(e, @field(value, info.field_names[0]));
            }
            try e.beginObject();
            try encodeFields(e, value, info.field_names, info.field_types);
            return e.endObject();
        },
        .@"union" => return encodeUnion(e, value),
        else => @compileError("json: cannot encode " ++ @typeName(T)),
    }
}

fn encodeSlice(e: *Encoder, value: anytype) Error!void {
    try e.beginArray();
    for (value) |item| try encode(e, item);
    return e.endArray();
}

/// Writes the fields of a struct into the object the caller has opened.
fn encodeFields(
    e: *Encoder,
    value: anytype,
    comptime names: []const [:0]const u8,
    comptime types: []const type,
) Error!void {
    const T = @TypeOf(value);
    inline for (names, types) |name, field_type| {
        const rule = comptime ruleFor(T, name);
        const field_value = @field(value, name);
        if (!rule.skip and !skipField(field_type, rule, field_value)) {
            try e.key(comptime rule.key orelse name);
            try encode(e, field_value);
        }
    }
}

fn encodeUnion(e: *Encoder, value: anytype) Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T).@"union";
    const tag = std.meta.activeTag(value);

    if (isBare(T)) {
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            if (tag == @field(std.meta.Tag(T), field_name)) {
                if (field_type == void) return;
                return encode(e, @field(value, field_name));
            }
        }
        unreachable;
    }

    // A bare variant is its payload, discriminator and all.
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (tag == @field(std.meta.Tag(T), field_name)) {
            if (comptime variantRule(T, field_name).bare) {
                if (field_type == void) return;
                return encode(e, @field(value, field_name));
            }
        }
    }

    const key: ?[]const u8 = tagKey(T);
    try e.beginObject();
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (tag == @field(std.meta.Tag(T), field_name)) {
            const variant = comptime variantRule(T, field_name);
            const name = comptime variant.key orelse field_name;
            if (comptime variant.bare) unreachable; // handled before the object
            if (key) |tag_key| {
                try e.key(tag_key);
                try e.string(name);
            }
            if (field_type == void) break;
            const payload = @field(value, field_name);
            if (comptime variant.flatten) {
                const payload_info = comptime switch (@typeInfo(field_type)) {
                    .@"struct" => |structure| structure,
                    else => @compileError("json: a flattened variant payload must be a struct"),
                };
                try encodeFields(e, payload, payload_info.field_names, payload_info.field_types);
            } else {
                try e.key(name);
                try encode(e, payload);
            }
            break;
        }
    }
    return e.endObject();
}

/// A field's rule, or the defaults when the type does not mention it.
fn ruleFor(comptime T: type, comptime name: []const u8) Rule {
    if (comptime !isContainer(T)) return .{};
    if (!@hasDecl(T, "json")) return .{};
    const config = @field(T, "json");
    if (!@hasField(@TypeOf(config), "fields")) return .{};
    const fields = @field(config, "fields");
    if (!@hasField(@TypeOf(fields), name)) return .{};
    const raw = @field(fields, name);
    return .{
        .key = if (@hasField(@TypeOf(raw), "key")) raw.key else null,
        .skip = @hasField(@TypeOf(raw), "skip") and raw.skip,
        .skip_if_null = !@hasField(@TypeOf(raw), "skip_if_null") or raw.skip_if_null,
        .skip_if_empty = @hasField(@TypeOf(raw), "skip_if_empty") and raw.skip_if_empty,
        .skip_if_false = @hasField(@TypeOf(raw), "skip_if_false") and raw.skip_if_false,
    };
}

/// A union variant's rule, or the defaults when the type does not mention it.
fn variantRule(comptime T: type, comptime name: []const u8) VariantRule {
    if (comptime !isContainer(T)) return .{};
    if (!@hasDecl(T, "json")) return .{};
    const config = @field(T, "json");
    if (!@hasField(@TypeOf(config), "fields")) return .{};
    const fields = @field(config, "fields");
    if (!@hasField(@TypeOf(fields), name)) return .{};
    const raw = @field(fields, name);
    return .{
        .key = if (@hasField(@TypeOf(raw), "key")) raw.key else null,
        .flatten = @hasField(@TypeOf(raw), "flatten") and raw.flatten,
        .bare = @hasField(@TypeOf(raw), "bare") and raw.bare,
    };
}

fn tagKey(comptime T: type) ?[]const u8 {
    if (comptime !isContainer(T)) return null;
    if (!@hasDecl(T, "json")) return null;
    const config = @field(T, "json");
    if (!@hasField(@TypeOf(config), "tag_key")) return null;
    return @field(config, "tag_key");
}

fn isBare(comptime T: type) bool {
    if (comptime !isContainer(T)) return false;
    if (!@hasDecl(T, "json")) return false;
    const config = @field(T, "json");
    if (!@hasField(@TypeOf(config), "bare")) return false;
    return @field(config, "bare");
}

/// Whether a type can carry declarations, and so a configuration.
fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn hasCustomEncode(comptime T: type) bool {
    if (comptime !isContainer(T)) return false;
    if (!@hasDecl(T, "json")) return false;
    const config = @field(T, "json");
    return @hasField(@TypeOf(config), "encode");
}

fn isRaw(comptime T: type) bool {
    if (comptime !isContainer(T)) return false;
    if (!@hasDecl(T, "json")) return false;
    const config = @field(T, "json");
    if (!@hasField(@TypeOf(config), "raw")) return false;
    return @field(config, "raw");
}

/// Whether a rule drops this field, given its value.
fn skipField(comptime T: type, comptime rule: Rule, value: T) bool {
    if (comptime rule.skip_if_null and @typeInfo(T) == .optional) {
        if (value == null) return true;
    }
    if (comptime rule.skip_if_empty and canBeEmpty(T)) {
        if (isEmpty(T, value)) return true;
    }
    if (comptime rule.skip_if_false and T == bool) {
        if (!value) return true;
    }
    return false;
}

/// Whether "empty" means anything for this type.
fn canBeEmpty(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |info| canBeEmpty(info.child),
        .pointer => |info| info.size == .slice,
        .array => true,
        else => false,
    };
}

fn isEmpty(comptime T: type, value: T) bool {
    return switch (@typeInfo(T)) {
        .optional => if (value) |inner| isEmpty(@TypeOf(inner), inner) else true,
        .pointer => |pointer| switch (pointer.size) {
            .slice => value.len == 0,
            else => false,
        },
        .array => value.len == 0,
        else => false,
    };
}

/// One field's rules, all optional.
pub const Rule = struct {
    key: ?[]const u8 = null,
    skip: bool = false,
    skip_if_null: bool = true,
    skip_if_empty: bool = false,
    skip_if_false: bool = false,
};

/// One union variant's rules, all optional.
pub const VariantRule = struct {
    key: ?[]const u8 = null,
    /// Write the payload's own fields inside the tag's object instead of
    /// nesting them under the variant name. The payload must be a struct.
    flatten: bool = false,
    /// Write the payload as the whole value: no tag, no object. Use it when
    /// the payload carries its own discriminator, as a file part's does.
    bare: bool = false,
};

fn writeString(out: *Io.Writer, value: []const u8) Error!void {
    try out.writeByte('"');
    var start: usize = 0;
    for (value, 0..) |byte, i| {
        const escape = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0c => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (byte < 0x20) null else continue,
        };
        try out.writeAll(value[start..i]);
        if (escape) |text| {
            try out.writeAll(text);
        } else {
            try out.print("\\u{x:0>4}", .{byte});
        }
        start = i + 1;
    }
    try out.writeAll(value[start..]);
    try out.writeByte('"');
}

/// Encodes `value` into a freshly allocated string.
pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var encoder: Encoder = .init(&out.writer);
    try encoder.write(value);
    return out.toOwnedSlice();
}

// ------------------------------------------------------------------ tests ---

// The encoder's own vocabulary, one case per knob. What the DeepSeek wire
// format needs from it is pinned by the client's tests.

const testing = std.testing;

fn expectJson(value: anytype, want: []const u8) !void {
    const encoded = try stringify(testing.allocator, value);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings(want, encoded);
}

const Example = struct {
    name: []const u8,
    gone: i64 = 0,
    renamed: i64 = 0,
    empty: []const u8 = "",
    flag: bool = false,
    ratio: f64 = 0.25,
    shape: Shape,
    schema: Raw,

    pub const json = .{
        .fields = .{
            .gone = .{ .skip = true },
            .renamed = .{ .key = "wire_name" },
            .empty = .{ .skip_if_empty = true },
            .flag = .{ .skip_if_false = true },
        },
    };
};

const Shape = union(enum) {
    text: []const u8,
    point: struct { x: i64, y: i64 },
    file: File,

    pub const json = .{
        .tag_key = "type",
        .fields = .{
            .point = .{ .flatten = true },
            .file = .{ .bare = true },
        },
    };
};

const File = union(enum) {
    id: struct { file_id: []const u8 },
    data: struct {
        data: []const u8,
        filename: ?[]const u8 = null,

        pub const json = .{ .fields = .{ .data = .{ .key = "file_data" } } };
    },

    pub const json = .{
        .tag_key = "type",
        .fields = .{
            .id = .{ .flatten = true, .key = "file" },
            .data = .{ .flatten = true, .key = "file" },
        },
    };
};

const schema_text =
    \\{"type":"object"}
;

test "the vocabulary encodes the documented shapes" {
    // Fields in declaration order, unset ones left out, a renamed key, an
    // empty string left out, a tag over a payload, a flattened payload, a bare
    // one, and a raw string written as JSON.
    var example: Example = .{
        .name = "n",
        .renamed = 3,
        .shape = .{ .point = .{ .x = 1, .y = 2 } },
        .schema = .{ .text = schema_text },
    };

    const point =
        \\{"name":"n","wire_name":3,"ratio":0.25,"shape":{"type":"point","x":1,"y":2},"schema":{"type":"object"}}
    ;
    try expectJson(example, point);

    example.shape = .{ .text = "hi" };
    const text =
        \\{"name":"n","wire_name":3,"ratio":0.25,"shape":{"type":"text","text":"hi"},"schema":{"type":"object"}}
    ;
    try expectJson(example, text);

    example.shape = .{ .file = .{ .id = .{ .file_id = "file-api-1" } } };
    const by_id =
        \\{"name":"n","wire_name":3,"ratio":0.25,"shape":{"type":"file","file_id":"file-api-1"},"schema":{"type":"object"}}
    ;
    try expectJson(example, by_id);

    example.shape = .{ .file = .{ .data = .{ .data = "data:image/png;base64,AA" } } };
    const inlined =
        \\{"name":"n","wire_name":3,"ratio":0.25,"shape":{"type":"file","file_data":"data:image/png;base64,AA"},"schema":{"type":"object"}}
    ;
    try expectJson(example, inlined);
}

test "control characters, quotes and backslashes are escaped" {
    try expectJson("a\x01b", "\"a\\u0001b\"");
    try expectJson("\t\r\n\"\\", "\"\\t\\r\\n\\\"\\\\\"");
}

test "nesting past the limit is an error rather than a crash" {
    var deepest: DeepNode = .{};
    var node: ?*const DeepNode = &deepest;
    var allocated: std.ArrayListUnmanaged(*const DeepNode) = .empty;
    defer {
        for (allocated.items) |item| testing.allocator.destroy(@constCast(item));
        allocated.deinit(testing.allocator);
    }
    var i: usize = 0;
    while (i < max_depth) : (i += 1) {
        const next = try testing.allocator.create(DeepNode);
        next.* = .{ .inner = node };
        try allocated.append(testing.allocator, next);
        node = next;
    }
    try testing.expectError(error.DepthTooDeep, stringify(testing.allocator, node.?.*));
}

const DeepNode = struct { inner: ?*const DeepNode = null };
