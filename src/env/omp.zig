//! The harness's view of the machine it runs on: the API keys omp has stored
//! for the providers we call, and the environment variables that override
//! them.
//!
//! Deciding points:
//!
//!   * The store is omp's own SQLite database, `~/.omp/agent/agent.db`, whose
//!     `auth_credentials` table holds one JSON object per credential. It is
//!     read through the `sqlite3` command-line tool rather than a linked
//!     SQLite, because the harness does not otherwise depend on one; a missing
//!     `sqlite3`, or a store that does not exist yet, is not an error, it just
//!     means there is no stored key.
//!   * A key is a `[]const u8` owned by the allocator the caller passed,
//!     whichever source it came from, so the caller always frees it and never
//!     has to ask where it came from.
//!   * A missing key is `null`, not an error: what to tell the operator —
//!     which variable to set, which `omp` command to run — is the caller's
//!     decision, and only the caller knows the provider's name for it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Where omp keeps the credentials it authenticates providers with, relative
/// to the home directory.
pub const credentials_path = ".omp/agent/agent.db";

/// A provider this harness can authenticate with: the name omp's store lists
/// it under, and the environment variable that takes precedence over the
/// stored key.
pub const Provider = struct {
    /// The `provider` column of `auth_credentials`.
    store_name: []const u8,
    /// Read first. A non-empty value is the key, whether or not a stored one
    /// exists.
    env_var: []const u8,

    pub const deepseek: Provider = .{
        .store_name = "deepseek",
        .env_var = "DEEPSEEK_API_KEY",
    };
};

pub const Error = Allocator.Error || error{
    /// The store name would not survive being written into the query.
    InvalidStoreName,
};

/// The key `provider` is authenticated with: its environment variable when
/// that is set and non-empty, otherwise the credential omp stores for it.
/// Null when neither has one.
pub fn apiKey(
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    provider: Provider,
) Error!?[]const u8 {
    try validateStoreName(provider.store_name);
    if (environ.get(provider.env_var)) |key| {
        if (key.len != 0) return try allocator.dupe(u8, key);
    }
    return storedApiKey(allocator, io, environ, provider.store_name);
}

/// The `key` field of the credential omp stores for `store_name`, or null when
/// there is no home directory, no store, no `sqlite3` on the PATH, or no
/// enabled row.
///
/// Only the `key` shape is read. A credential omp logs in to and refreshes —
/// an OAuth token, stored under `access` — is not an API key, and is left
/// alone.
fn storedApiKey(
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store_name: []const u8,
) Error!?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    const db = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, credentials_path });
    defer allocator.free(db);
    const query = try std.fmt.allocPrint(allocator, newest_credential_sql, .{store_name});
    defer allocator.free(query);

    const argv = [_][]const u8{ "sqlite3", db, query };
    // A store that is not there, or a machine without the tool, leaves the
    // process with nothing to fall back to rather than a failure to report.
    const run = std.process.run(allocator, io, .{ .argv = &argv }) catch return null;
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    if (run.term.exited != 0) return null;

    return try jsonStringField(allocator, run.stdout, "key");
}

/// The `data` of the newest credential omp has enabled for one provider.
const newest_credential_sql =
    "SELECT data FROM auth_credentials WHERE provider='{s}'" ++
    " AND disabled_cause IS NULL ORDER BY updated_at DESC LIMIT 1;";

/// `store_name` is written into a single-quoted SQL literal, so a quote in it
/// would end the literal and leave the rest of the name to be read as SQL. The
/// names this file defines carry none; a caller-supplied one that does is
/// rejected instead of run.
fn validateStoreName(store_name: []const u8) error{InvalidStoreName}!void {
    if (store_name.len == 0) return error.InvalidStoreName;
    if (std.mem.indexOfScalar(u8, store_name, '\'') != null) return error.InvalidStoreName;
}

/// The string value of `field` in a flat JSON object, e.g. the `sk-...` in
/// `{"key":"sk-...","source":"login"}`. Keys and tokens carry no escapes, so a
/// scan for the quoted field is enough; null when the field is absent or
/// empty.
fn jsonStringField(
    allocator: Allocator,
    object: []const u8,
    comptime field: []const u8,
) Allocator.Error!?[]const u8 {
    const needle = "\"" ++ field ++ "\":\"";
    const start = std.mem.indexOf(u8, object, needle) orelse return null;
    const value_start = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, object, value_start, '"') orelse return null;
    if (end == value_start) return null;
    return try allocator.dupe(u8, object[value_start..end]);
}

test {
    _ = @import("omp_test.zig");
}
