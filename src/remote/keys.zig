//! The harness's view of the machine it runs on: the API keys omp has stored
//! for the providers we call, and the environment variables that override
//! them.
//!
//! Design decisions:
//!
//!   * The store is omp's own SQLite database, `~/.omp/agent/agent.db`, whose
//!     `auth_credentials` table holds one JSON object per credential. Reading
//!     it is left to `omp-keys.py`, a Python helper installed under the
//!     harness's install root, so that SQLite stays out of this build: the
//!     harness links no SQL, and the machine's own Python reads the store with
//!     the SQLite it already has.
//!   * The helper is handed a provider name and an absolute path, never a
//!     statement, so nothing this file passes can be SQL, and the helper needs
//!     no environment of its own to find the store.
//!   * A key is a `[]const u8` owned by the allocator the caller passed,
//!     whichever source it came from, so the caller always frees it and never
//!     has to ask where it came from.
//!   * A store that is not there yields no key, as does a credential that is
//!     not an API key. A store that is there and could not be read is an
//!     error, because that is not "no credential", it is a store that is not
//!     what this file thinks it is.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Where omp keeps the credentials it authenticates providers with, relative
/// to the home directory.
pub const credentials_path = ".omp/agent/agent.db";

/// The helper, under the install root's `lib`. Not `bin`: a program belongs
/// there, and this is not one, it is run through `python3`. Keep in step with
/// build.zig, which installs it at exactly this path.
const helper_path = "lib/harness1/omp-keys.py";

/// Names the install root, for a program that is not where the install put it.
/// The playground runs out of the build cache and is told `zig-out`; without
/// it, the root is taken to be the directory the running executable's `bin` is
/// inside.
pub const install_root_var = "HARNESS1_INSTALL_ROOT";

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

    pub const lithosai: Provider = .{
        .store_name = "lithosai",
        .env_var = "LITHOSAI_API_KEY",
    };
};

/// The ways reading the store can fail. A store that is absent, or that has no
/// credential for the provider, is not among them.
pub const Error = Allocator.Error || error{
    /// The helper could not be run: `python3` is not on the PATH, or no
    /// `omp-keys.py` is where one is expected. The store was never asked.
    HelperUnavailable,
    /// The helper ran and could not read the store. It said why on its stderr,
    /// which is dropped: the caller can do nothing with it that this error
    /// does not already say.
    HelperFailed,
};

pub fn apiKey(
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    provider: Provider,
) Error!?[]const u8 {
    if (environ.get(provider.env_var)) |key| {
        if (key.len != 0) return try allocator.dupe(u8, key);
    }
    return storedApiKey(allocator, io, environ, provider.store_name);
}

/// The credential omp stores for `store_name`, or null when none is enabled.
fn storedApiKey(
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store_name: []const u8,
) Error!?[]const u8 {
    const home = environ.get("HOME") orelse return null;
    const db = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, credentials_path });
    defer allocator.free(db);
    // Nothing to read: do not go looking for something to read it with.
    std.Io.Dir.cwd().access(io, db, .{}) catch return null;

    const helper = try helperPath(allocator, io, environ);
    defer allocator.free(helper);
    // Separated from the store's own failures, so that a broken install does
    // not read as a store that refused to answer.
    std.Io.Dir.cwd().access(io, helper, .{}) catch return error.HelperUnavailable;

    const argv = [_][]const u8{ "python3", helper, db, store_name };
    const answered = std.process.run(allocator, io, .{ .argv = &argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HelperUnavailable,
    };
    defer allocator.free(answered.stdout);
    defer allocator.free(answered.stderr);

    const exit_code = switch (answered.term) {
        .exited => |code| code,
        else => return error.HelperFailed,
    };
    switch (exit_code) {
        // The helper's contract, read off its exit status rather than guessed
        // from its output: a key, or nothing and a reason.
        0 => {},
        1 => return null,
        else => return error.HelperFailed,
    }

    const key = std.mem.trim(u8, answered.stdout, " \t\r\n");
    if (key.len == 0) return null;
    return try allocator.dupe(u8, key);
}

fn helperPath(
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) Error![]u8 {
    if (environ.get(install_root_var)) |root| {
        if (root.len != 0) return try std.fs.path.join(allocator, &.{ root, helper_path });
    }
    const executable_dir = std.process.executableDirPathAlloc(io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Nowhere to look is the same answer as looking and finding nothing.
        else => return error.HelperUnavailable,
    };
    defer allocator.free(executable_dir);
    // An executable's directory is the root's `bin`, so the root is its
    // parent. Left unresolved: `..` and the `lib` below it are the install
    // layout, and spelling that out again would only restate the `join`.
    return std.fs.path.join(allocator, &.{ executable_dir, "..", helper_path });
}

// Tests: only the half that needs no store — reading the environment
// variable. A store built here would pin this file's idea of omp's schema
// rather than omp's — the same column and field names the module reads,
// written twice from the same head, where agreement proves nothing. The store
// half is checked by running the playground against the real one.

const deepseek = Provider.deepseek;

/// A home directory that is not there, so that the store cannot be opened and
/// whatever the lookup returns came from the environment.
const no_home = "/nonexistent/harness1-test-home";

test "the environment variable is the key when it is set" {
    const allocator = testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("DEEPSEEK_API_KEY", "sk-from-environment");
    try environ.put("HOME", no_home);

    const key = (try apiKey(allocator, testing.io, &environ, deepseek)) orelse
        return error.ExpectedKey;
    // The key is the caller's, not the environment's own storage: freeing it
    // must leave the map holding what it held.
    defer allocator.free(key);
    try testing.expectEqualStrings("sk-from-environment", key);
    try testing.expectEqualStrings("sk-from-environment", environ.get("DEEPSEEK_API_KEY").?);
}

test "an empty environment variable is not a key" {
    const allocator = testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("DEEPSEEK_API_KEY", "");
    try environ.put("HOME", no_home);

    try testing.expectEqual(null, try apiKey(allocator, testing.io, &environ, deepseek));
}

test "neither a variable nor a home directory is null rather than an error" {
    const allocator = testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    try testing.expectEqual(null, try apiKey(allocator, testing.io, &environ, deepseek));
}
