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
    // runs it through `python3`. src/env/omp.zig looks for exactly this path
    // under the install root, so the two have to agree.
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

    // The DeepSeek playground under src/research. It is a scratch program, not
    // part of the library, so it is neither installed by the default step nor
    // built with it: `zig build` stays off the network and builds only the
    // harness. `zig build deepseek_playground` compiles and runs it.
    const playground = b.addExecutable(.{
        .name = "deepseek_playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/research/deepseek_playground.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "harness1", .module = mod },
            },
        }),
    });

    // One test executable per module, since a test binary only collects the
    // files one root module reaches.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Runs the playground against the live API. Separate from the default
    // step, which must not need a key or a network.
    const playground_step = b.step("deepseek_playground", "Run the DeepSeek playground");
    const run_playground = b.addRunArtifact(playground);
    run_playground.addPassthruArgs();
    // The playground runs out of the build cache rather than from the install
    // tree, so it is told where that tree is instead of finding it beside
    // itself. The value is relative and setCwd pins what it is relative to —
    // the build root, where the default prefix is `zig-out`. Installing
    // elsewhere with `-p` means naming that prefix here yourself; this step
    // cannot see it, since Zig resolves the prefix when it installs rather
    // than when it configures.
    run_playground.setCwd(b.path("."));
    run_playground.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run_playground.step.dependOn(&credentials.step);
    playground_step.dependOn(&run_playground.step);
}
