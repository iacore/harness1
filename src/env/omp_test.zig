//! Tests for the omp environment module.
//!
//! Only the half that needs no store: reading the environment variable, and
//! rejecting a store name that would break the query. A store built here would
//! pin this file's idea of omp's schema rather than omp's — the same column
//! and field names the module reads, written twice from the same head, where
//! agreement proves nothing. The store half is checked by running the
//! playground against the real one.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const omp = @import("omp.zig");

const deepseek = omp.Provider.deepseek;

/// A home directory that is not there, so that the store cannot be opened and
/// whatever the lookup returns came from the environment.
const no_home = "/nonexistent/harness1-test-home";

test "the environment variable is the key when it is set" {
    const allocator = testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("DEEPSEEK_API_KEY", "sk-from-environment");
    try environ.put("HOME", no_home);

    const key = (try omp.apiKey(allocator, testing.io, &environ, deepseek)) orelse
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

    try testing.expectEqual(null, try omp.apiKey(allocator, testing.io, &environ, deepseek));
}

test "neither a variable nor a home directory is null rather than an error" {
    const allocator = testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    try testing.expectEqual(null, try omp.apiKey(allocator, testing.io, &environ, deepseek));
}

test "a store name that would break the query is rejected" {
    const allocator = testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    const injected: omp.Provider = .{
        .store_name = "deepseek' OR '1'='1",
        .env_var = "DEEPSEEK_API_KEY",
    };
    try testing.expectError(
        error.InvalidStoreName,
        omp.apiKey(allocator, testing.io, &environ, injected),
    );
}
