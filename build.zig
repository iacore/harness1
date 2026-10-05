const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = harnessModule(b, target);

    const credentials = installOmpKeys(b);
    b.getInstallStep().dependOn(&credentials.step);

    // One test executable per module, since a test binary only collects the
    // files one root module reaches.
    const test_step = b.step("test", "Run tests");
    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // `ui` is developer-only: the published package carries the library and no
    // program, so the exe exists only in a checkout that has it.
    if (b.root.access(b.graph.io, "ui/main.zig", .{})) |_| {
        b.dependOnDirectoryContents(b.path("ui"));
        // The UI embeds CPython for its scripting layer, so it links libc and
        // libpython and compiles the shim. `python3-config` is asked for the
        // include path and the libraries, so no Python version is written into
        // this file.
        const ui = b.createModule(.{
            .root_source_file = b.path("ui/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        });
        ui.addCSourceFile(.{ .file = b.path("ui/python_shim.c"), .flags = &.{"-std=c99"} });
        for (pythonFlags(b, &.{ "--embed", "--includes" }, "-I")) |path| ui.addIncludePath(.{ .cwd_relative = path });
        for (pythonFlags(b, &.{ "--embed", "--ldflags" }, "-l")) |name| ui.linkSystemLibrary(name, .{});
        const exe = b.addExecutable(.{ .name = "run1", .root_module = ui });
        b.installArtifact(exe);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        // Runs the installed artifact rather than the one in the cache, so a
        // relative path such as the helper's is read from where it was installed.
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();

        const exe_tests = b.addTest(.{ .root_module = exe.root_module });
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);

        test_step.dependOn(&addPathsOnlyTest(b).step);
    } else |_| {}

    // Nothing here needs Python but the helper above. The scratch client under
    // `research/python`, the research programs under `research`, and the targets
    // that run them live in `build.research.zig`, so they stay out of the
    // published package and out of `zig build -l`.
}

/// Only the declarations `core/root.zig` re-exports are reachable by an
/// importer, so anything meant to be public has to be named there.
///
/// The transport is libcurl, because the endpoint serves HTTP/2 and Zig's
/// `std.http.Client` speaks HTTP/1.1 only; see `core/remote/curl.zig` and
/// `research/http-client.dj`. That makes the module link libc and the system
/// libcurl, and a consumer of the package has to have both. The header reaches
/// Zig through translate-c, since 0.17 removed `@cImport`.
pub fn harnessModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const mod = b.addModule("run1", .{
        .root_source_file = b.path("core/root.zig"),
        .target = target,
        .link_libc = true,
    });
    const curl_c = b.addTranslateC(.{
        .root_source_file = b.path("core/curl_shim.c"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    curl_c.linkSystemLibrary("curl", .{});
    mod.addImport("curl", curl_c.createModule());
    mod.linkSystemLibrary("curl", .{});
    return mod;
}

/// omp's store is a SQLite database, and reading it is left to a Python helper
/// rather than to a linked library: the build stays free of SQL, and of libc
/// with it. Not installed to `bin`, because it is not a program — the harness
/// runs it through `python3`. core/remote/keys.zig looks for exactly this path
/// under the install root, so the two have to agree.
pub fn installOmpKeys(b: *std.Build) *std.Build.Step.InstallFile {
    return b.addInstallFileWithDir(
        b.path("core/remote/omp-keys.py"),
        .lib,
        "run1/omp-keys.py",
    );
}

/// What a consumer of the package receives is `build.zig.zon`'s `.paths` and
/// nothing else — `ui` is developer-only, and the program is gated on it. A
/// whitelisted tree can still fail to build when a shipped file reaches for one
/// that was left out, and no ordinary build of the dev tree catches that, so
/// the tests rebuild the package from the whitelist alone under a scratch
/// directory with the same compiler.
fn addPathsOnlyTest(b: *std.Build) *std.Build.Step.Run {
    const script =
        \\set -eu
        \\zig=$1 src=$2
        \\shift 2
        \\dest=$(mktemp -d)
        \\trap 'rm -rf "$dest"' EXIT
        \\for p in "$@"; do
        \\    mkdir -p "$dest/$(dirname "$p")"
        \\    cp -R "$src/$p" "$dest/$p"
        \\done
        \\cd "$dest"
        \\"$zig" build
        \\"$zig" build test
    ;
    const run = b.addSystemCommand(&.{ "sh", "-c", script, "sh", b.graph.zig_exe });
    run.addDirectoryArg(b.path("."));
    for (packagePaths(b)) |p| run.addArg(p);
    // The scratch directory is outside the cache, so the step cannot be cached.
    run.has_side_effects = true;
    return run;
}

/// The tokens `python3-config` prints with `prefix` stripped, so the embedded
/// interpreter is discovered rather than pinned to a version in this file.
fn pythonFlags(b: *std.Build, args: []const []const u8, prefix: []const u8) []const []const u8 {
    const allocator = b.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(allocator, "python3-config") catch @panic("OOM");
    for (args) |arg| argv.append(allocator, arg) catch @panic("OOM");
    const text = b.run(argv.items);

    var flags: std.ArrayList([]const u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, text, " \n");
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, prefix)) {
            flags.append(allocator, token[prefix.len..]) catch @panic("OOM");
        }
    }
    return flags.toOwnedSlice(allocator) catch @panic("OOM");
}

/// The `.paths` list, read from `build.zig.zon` so that the test above cannot
/// drift from what the package actually ships.
fn packagePaths(b: *std.Build) []const []const u8 {
    const arena = b.graph.arena;
    b.dependOnFileContents(b.path("build.zig.zon"));
    const zon = b.root.resolvePosix(arena, "build.zig.zon") catch @panic("OOM");
    const source = zon.root_dir.handle.readFileAllocOptions(
        b.graph.io,
        zon.sub_path,
        arena,
        .limited(1 << 20),
        .of(u8),
        0,
    ) catch |err| std.debug.panic("cannot read build.zig.zon: {t}", .{err});
    const Manifest = struct { paths: []const []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| std.debug.panic("cannot parse build.zig.zon: {t}", .{err});
    return manifest.paths;
}