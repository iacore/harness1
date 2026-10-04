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

    // `src/python/` is a scratch client that talks to the API directly, in
    // Python and nothing else: it neither builds from nor loads anything here,
    // so the harness needs no Python but the helper above. The one part the
    // build has in it is `zig build check_python`, which runs the type checker
    // over it — `ty.toml` is what that check reads.

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

    // The 正見/正思惟 experiment under src/research/zhengjian. Like the
    // playground, these are scratch programs: neither installed nor built by
    // the default step, which stays off the network.
    //
    // `judge` is one program and not a library on purpose — see its header.
    const judge_exe = b.addExecutable(.{
        .name = "zhengjian_judger",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/research/zhengjian/judger.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "harness1", .module = mod },
            },
        }),
    });

    const judge_step = b.step("judge", "Judge one answer against a rubric");
    const run_judge = b.addRunArtifact(judge_exe);
    run_judge.addPassthruArgs();
    run_judge.setCwd(b.path("."));
    run_judge.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run_judge.step.dependOn(&credentials.step);
    judge_step.dependOn(&run_judge.step);

    const search_exe = b.addExecutable(.{
        .name = "zhengjian_search",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/research/zhengjian/search.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "harness1", .module = mod },
            },
        }),
    });

    // The searcher is started with the judge's path already filled in, so the
    // two are built and wired by the same step rather than by whoever
    // remembers to pass `--judger`.
    const search_step = b.step("search", "Search prompting techniques against the corpus");
    const run_search = b.addRunArtifact(search_exe);
    run_search.addArg("--judger");
    run_search.addArtifactArg(judge_exe);
    run_search.addPassthruArgs();
    run_search.setCwd(b.path("."));
    run_search.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run_search.step.dependOn(&credentials.step);
    search_step.dependOn(&run_search.step);

    // The LithosAI roster generator. A scratch program like the playground:
    // it needs a key and a network, so it is not installed and not built by
    // the default step. It rewrites src/remote/lithos_models.zig in place,
    // which the default build then compiles as ordinary source — that is what
    // keeps installation independent of generation.
    const lithos_models_exe = b.addExecutable(.{
        .name = "lithos_models_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/research/lithos_models_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "harness1", .module = mod },
            },
        }),
    });

    const lithos_models_step = b.step("lithos_models", "Regenerate src/remote/lithos_models.zig from GET /v1/models");
    const run_lithos_models = b.addRunArtifact(lithos_models_exe);
    run_lithos_models.addPassthruArgs();
    run_lithos_models.setCwd(b.path("."));
    run_lithos_models.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run_lithos_models.step.dependOn(&credentials.step);
    lithos_models_step.dependOn(&run_lithos_models.step);

    // Scratch too: it prints what each roster model does with the off switch
    // and a mid-band top_p.
    const lithos_probe_exe = b.addExecutable(.{
        .name = "lithos_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/research/lithos_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "harness1", .module = mod },
            },
        }),
    });

    const lithos_probe_step = b.step("lithos_probe", "Probe the per-model constraints of the LithosAI roster");
    const run_lithos_probe = b.addRunArtifact(lithos_probe_exe);
    run_lithos_probe.addPassthruArgs();
    run_lithos_probe.setCwd(b.path("."));
    run_lithos_probe.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run_lithos_probe.step.dependOn(&credentials.step);
    lithos_probe_step.dependOn(&run_lithos_probe.step);

    // One test executable per module, since a test binary only collects the
    // files one root module reaches.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // The Python client under src/python, type-checked. Not part of the default
    // step: that has to build the harness with nothing but Zig, and `ty` is not
    // vendored, so this is the step that needs it on the PATH. Installing it is
    // `uv tool install ty` (or pipx, or `pip install ty`); `ty.toml` at the
    // root says what is checked and how strictly.
    const check_python_step = b.step("check_python", "Type-check the Python client under src/python");
    const ty_check = b.addSystemCommand(&.{ "ty", "check" });
    // Run from the build root, where `ty.toml` is, so the step checks this
    // checkout's Python rather than whatever directory it was invoked from.
    ty_check.setCwd(b.path("."));
    check_python_step.dependOn(&ty_check.step);

    // Runs the playground against the live API. Separate from the default
    // step, which must not need a key or a network.
    const playground_step = b.step("deepseek_playground", "Run the DeepSeek playground");
    const run_playground = b.addRunArtifact(playground);
    run_playground.addPassthruArgs();
    // The playground runs out of the build cache rather than the install tree,
    // so it is told where that tree is instead of finding it beside itself.
    // The value is relative and setCwd pins what it is relative to — the build
    // root, where the default prefix is `zig-out`. Installing elsewhere with
    // `-p` means naming that prefix here yourself; this step cannot see it,
    // since Zig resolves the prefix when it installs, not when it configures.
    run_playground.setCwd(b.path("."));
    run_playground.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run_playground.step.dependOn(&credentials.step);
    playground_step.dependOn(&run_playground.step);
}
