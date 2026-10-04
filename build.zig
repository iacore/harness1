const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // src/root.zig is the module's entry point: only the declarations it
    // re-exports are reachable by an importer, so anything meant to be public
    // has to be named there.
    const mod = b.addModule("harness1", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // omp's credential store is a SQLite database, and reading it is left to a
    // Python helper rather than to a linked library: the build stays free of
    // SQL, and of libc with it.
    //
    // It is not installed to `bin` because it is not a program — the harness
    // runs it through `python3`. src/remote/keys.zig looks for exactly this
    // path under the install root, so the two have to agree.
    const credentials = b.addInstallFileWithDir(
        b.path("src/credentials.py"),
        .lib,
        "harness1/credentials.py",
    );
    b.getInstallStep().dependOn(&credentials.step);

    const exe = b.addExecutable(.{
        .name = "harness1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "harness1", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    // Runs the installed artifact rather than the one in the cache, so a
    // relative path such as the helper's is read from where it was installed.
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // One test executable per module, since a test binary only collects the
    // files one root module reaches.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Nothing here needs Python but the helper above. The scratch client under
    // `src/python`, the research programs under `src/research`, and the targets
    // that run them live in `build.research.zig`, so they stay out of the
    // published package and out of `zig build -l`.
}
