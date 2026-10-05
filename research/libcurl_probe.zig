//! Proves libcurl links from Zig and negotiates HTTP/2 with the LithosAI edge,
//! and shows what "force h2" does to a server that does not offer it.
//!
//!   zig build --build-file ./build.research.zig libcurl_probe -- <url> <h2|h1>
//!
//! Exit status is non-zero when h2 was asked for and not negotiated, which is
//! the abort condition the client would run under.

const std = @import("std");
const c = @import("curl");

const default_url: [*:0]const u8 = "https://api.lithosai.cloud/v1/models";

pub fn main(init: std.process.Init) !void {
    const args = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    const url: [*:0]const u8 = if (args.len > 1) args[1].ptr else default_url;
    const want = if (args.len > 2) args[2] else "h2";

    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
    defer c.curl_global_cleanup();

    const info = c.curl_version_info(c.CURLVERSION_NOW) orelse return error.NoVersionInfo;
    const v = info[0];
    std.debug.print("libcurl {s}  HTTP2={d} HTTP3={d}  nghttp2={s}\n", .{
        std.mem.span(v.version),
        @intFromBool(v.features & c.CURL_VERSION_HTTP2 != 0),
        @intFromBool(v.features & c.CURL_VERSION_HTTP3 != 0),
        if (v.nghttp2_version) |s| std.mem.span(s) else "(none)",
    });

    const h = c.curl_easy_init() orelse return error.InitFailed;
    defer c.curl_easy_cleanup(h);

    try setopt(h, c.CURLOPT_URL, url);
    try setopt(h, c.CURLOPT_NOBODY, @as(c_long, 1));
    try setopt(h, c.CURLOPT_HTTP_VERSION, @as(c_long, if (std.mem.eql(u8, want, "h1"))
        c.CURL_HTTP_VERSION_1_1
    else
        c.CURL_HTTP_VERSION_2TLS));

    const rc = c.curl_easy_perform(h);
    if (rc != c.CURLE_OK) {
        std.debug.print("{s}: perform failed: {s}\n", .{ want, std.mem.span(c.curl_easy_strerror(rc)) });
        return error.PerformFailed;
    }

    var code: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &code);
    var version: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_HTTP_VERSION, &version);

    std.debug.print("{s}: status={d} negotiated={s}\n", .{ want, code, versionName(version) });

    if (std.mem.eql(u8, want, "h2") and version != c.CURL_HTTP_VERSION_2_0) {
        std.debug.print("abort: h2 was required and not negotiated\n", .{});
        return error.Downgraded;
    }
}

fn versionName(v: c_long) []const u8 {
    return switch (v) {
        c.CURL_HTTP_VERSION_1_0 => "HTTP/1.0",
        c.CURL_HTTP_VERSION_1_1 => "HTTP/1.1",
        c.CURL_HTTP_VERSION_2_0 => "HTTP/2",
        c.CURL_HTTP_VERSION_3 => "HTTP/3",
        else => "?",
    };
}

/// `curl_easy_setopt` is variadic; the value's C type depends on the option, so
/// each call site states it.
fn setopt(handle: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(handle, option, value) != c.CURLE_OK) return error.SetOptFailed;
}