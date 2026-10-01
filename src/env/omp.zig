//! The harness's view of the machine it runs on: the API keys omp has stored
//! for the providers we call, and the environment variables that override
//! them.
//!
//! Deciding points:
//!
//!   * The store is omp's own SQLite database, `~/.omp/agent/agent.db`, whose
//!     `auth_credentials` table holds one JSON object per credential. It is
//!     opened read-only through the SQLite library the harness links, with the
//!     provider name bound as a parameter rather than written into the
//!     statement; a store that does not exist yet is not an error, it just
//!     means there is no stored key.
//!   * A key is a `[]const u8` owned by the allocator the caller passed,
//!     whichever source it came from, so the caller always frees it and never
//!     has to ask where it came from.
//!   * A missing key is `null`, not an error: what to tell the operator —
//!     which variable to set, which `omp` command to run — is the caller's
//!     decision, and only the caller knows the provider's name for it. A store
//!     that is there and will not answer is an error instead, because that is
//!     not "no credential", it is a store that is not what this file thinks it
//!     is.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sqlite = @import("../root.zig").sqlite;

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

/// The ways reading the store can fail. A store that is absent, or that has no
/// credential for the provider, is not among them.
pub const Error = sqlite.Error;

/// The key `provider` is authenticated with: its environment variable when
/// that is set and non-empty, otherwise the credential omp stores for it.
/// Null when neither has one.
pub fn apiKey(
    allocator: Allocator,
    environ: *const std.process.Environ.Map,
    provider: Provider,
) Error!?[]const u8 {
    if (environ.get(provider.env_var)) |key| {
        if (key.len != 0) return try allocator.dupe(u8, key);
    }
    return storedApiKey(allocator, environ, provider.store_name);
}

/// The `key` field of the credential omp stores for `store_name`, or null when
/// there is no home directory, no store, or no enabled row.
///
/// Only the `key` shape is read. A credential omp logs in to and refreshes —
/// an OAuth token, stored under `access` — is not an API key, and is left
/// alone.
fn storedApiKey(
    allocator: Allocator,
    environ: *const std.process.Environ.Map,
    store_name: []const u8,
) Error!?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    const db = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, credentials_path });
    defer allocator.free(db);

    const data = try sqlite.queryFirstText(allocator, db, newest_credential_sql, store_name) orelse
        return null;
    defer allocator.free(data);

    return try jsonStringField(allocator, data, "key");
}

/// The `data` of the newest credential omp has enabled for one provider. `?1`
/// is the provider name, bound by the caller rather than written in here.
const newest_credential_sql: [:0]const u8 =
    "SELECT data FROM auth_credentials WHERE provider=?1" ++
    " AND disabled_cause IS NULL ORDER BY updated_at DESC LIMIT 1;";

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
