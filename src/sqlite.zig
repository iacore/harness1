//! The few SQLite entry points the harness calls.
//!
//! They are declared here rather than through `@cImport`, so the build needs
//! the library but not its headers, and the module stays free of translated C.
//!
//! The API is deliberately one call wide — open read-only, prepare one
//! statement with a `?1` parameter, bind one text value, read one text column —
//! because one call is what the credential store needs. A general binding
//! would be a different, larger thing.
//!
//! Deciding points:
//!
//!   * The parameter is bound, never interpolated, so a value reaching SQL as
//!     text cannot end the statement or match a row it was not meant to.
//!   * The statement is prepared before the parameter exists, so there is no
//!     path where a caller's string is parsed as SQL.
//!   * An absent database is null, not an error: no store yet is a normal state
//!     for a machine that has not signed in to anything. A database that is
//!     there but cannot be read or prepared is an error, since that means the
//!     store is not what we think it is.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `sqlite3_open_v2` flags and result codes.
const SQLITE_OK = 0;
const SQLITE_CANTOPEN = 14;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READONLY = 0x0000_0001;

/// `SQLITE_TRANSIENT`, spelled `(sqlite3_destructor_type)-1`: tells SQLite to
/// take its own copy of the bound text rather than keep the caller's pointer.
const transient: ?*const fn (?*anyopaque) callconv(.c) void =
    @ptrFromInt(std.math.maxInt(usize));

const Database = opaque {};
const Statement = opaque {};

extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    db: *?*Database,
    flags: c_int,
    vfs: ?[*:0]const u8,
) c_int;

extern fn sqlite3_prepare_v2(
    db: ?*Database,
    sql: [*:0]const u8,
    length: c_int,
    stmt: *?*Statement,
    tail: ?*?[*:0]const u8,
) c_int;

extern fn sqlite3_bind_text(
    stmt: ?*Statement,
    index: c_int,
    text: [*]const u8,
    length: c_int,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;

extern fn sqlite3_step(stmt: ?*Statement) c_int;
extern fn sqlite3_column_text(stmt: ?*Statement, column: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: ?*Statement, column: c_int) c_int;
extern fn sqlite3_finalize(stmt: ?*Statement) c_int;
extern fn sqlite3_close(db: ?*Database) c_int;

pub const Error = Allocator.Error || error{
    /// The database exists but would not open.
    OpenFailed,
    /// `sql` is not a statement this database accepts — a table that is not
    /// there, most likely.
    PrepareFailed,
    /// The parameter would not bind.
    BindFailed,
    /// The statement ran and failed.
    StepFailed,
};

/// Opens `path` read-only and runs `sql` with `parameter` bound to `?1`,
/// returning the first column of the first row copied into `allocator`.
///
/// Null when the database is not there, when the statement matched no row, or
/// when that column is SQL NULL. The caller owns the result.
pub fn queryFirstText(
    allocator: Allocator,
    path: []const u8,
    sql: [:0]const u8,
    parameter: []const u8,
) Error!?[]u8 {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    var db: ?*Database = null;
    const opened = sqlite3_open_v2(path_z.ptr, &db, SQLITE_OPEN_READONLY, null);
    if (opened == SQLITE_CANTOPEN) {
        _ = sqlite3_close(db);
        return null;
    }
    if (opened != SQLITE_OK) {
        _ = sqlite3_close(db);
        return error.OpenFailed;
    }
    // Registered before the statement's, so the statement is finalized first:
    // SQLite refuses to close a database that still has one open.
    defer _ = sqlite3_close(db);

    var stmt: ?*Statement = null;
    if (sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
        return error.PrepareFailed;
    }
    defer _ = sqlite3_finalize(stmt);

    if (sqlite3_bind_text(stmt, 1, parameter.ptr, @intCast(parameter.len), transient) != SQLITE_OK) {
        return error.BindFailed;
    }

    return switch (sqlite3_step(stmt)) {
        SQLITE_DONE => null,
        SQLITE_ROW => blk: {
            const text = sqlite3_column_text(stmt, 0) orelse break :blk null;
            const length: usize = @intCast(sqlite3_column_bytes(stmt, 0));
            break :blk try allocator.dupe(u8, text[0..length]);
        },
        else => error.StepFailed,
    };
}
