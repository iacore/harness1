// Targets only a developer of this project runs: the scratch programs under
// src/research, and the Python type check. They live here rather than in
// `build.zig` so `zig build -l` lists only what the library's user runs, and
// the file is left out of `build.zig.zon`'s `.paths` so the published package
// carries no research.
//
// Every path below resolves from the repository root, so run it there:
//
//     zig build --build-file ./build.research.zig <step>
//
// Most targets need a key and a network, so none is part of the default step.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("harness1", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // src/remote/keys.zig reads the harness's credential store by running this
    // file, so both sides fix the same path in the install tree:
    // lib/harness1/credentials.py under the prefix. The run steps below hand
    // each program the prefix to find it.
    const credentials = b.addInstallFileWithDir(
        b.path("src/credentials.py"),
        .lib,
        "harness1/credentials.py",
    );

    const playground_exe = b.addExecutable(.{
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
    _ = addRunStep(b, playground_exe, &credentials.step, "deepseek_playground", "Run the DeepSeek playground");

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
    _ = addRunStep(b, judge_exe, &credentials.step, "judge", "Judge one answer against a rubric");

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
    // remembers to pass `--judger`. `addRunStep` cannot do it: it appends the
    // command line's own arguments, which have to follow `--judger`.
    const search_step = b.step("search", "Search prompting techniques against the corpus");
    const run_search = b.addRunArtifact(search_exe);
    run_search.addArg("--judger");
    run_search.addArtifactArg(judge_exe);
    run_search.addPassthruArgs();
    run_search.setCwd(b.path("."));
    run_search.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run_search.step.dependOn(&credentials.step);
    search_step.dependOn(&run_search.step);

    // Rewrites src/remote/lithos_models.zig in place, which the library's build
    // then compiles as ordinary source — installation does not depend on
    // generation.
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
    _ = addRunStep(b, lithos_models_exe, &credentials.step, "lithos_models", "Regenerate src/remote/lithos_models.zig from GET /v1/models");

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
    _ = addRunStep(b, lithos_probe_exe, &credentials.step, "lithos_probe", "Probe the per-model constraints of the LithosAI roster");

    const lithos_strict_exe = b.addExecutable(.{
        .name = "lithos_strict_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/research/lithos_strict_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "harness1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, lithos_strict_exe, &credentials.step, "lithos_strict", "Probe whether LithosAI enforces strict tool schemas");

    // `ty` is not vendored, so this step needs it on the PATH: `uv tool install
    // ty` (or pipx, or `pip install ty`). `ty.toml` at the root says what is
    // checked and how strictly, which is why this runs from the build root.
    const check_python_step = b.step("check_python", "Type-check the Python client under src/python");
    const ty_check = b.addSystemCommand(&.{ "ty", "check" });
    ty_check.setCwd(b.path("."));
    check_python_step.dependOn(&ty_check.step);
}

// Registers `exe` as a top-level step that runs it with whatever follows `--`
// on the command line.
//
// A scratch program runs out of the build cache, not the install tree, so it
// needs to be told where that tree is: `HARNESS1_INSTALL_ROOT` is the default
// prefix `zig-out`, relative to the build root that `setCwd` pins. Installing
// elsewhere with `-p` means naming that prefix here too; this cannot see the
// prefix Zig resolves at install time. The credentials install is a dependency
// because the program reads the helper from inside that tree.
fn addRunStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    credentials: *std.Build.Step,
    name: []const u8,
    description: []const u8,
) *std.Build.Step.Run {
    const step = b.step(name, description);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.setCwd(b.path("."));
    run.setEnvironmentVariable("HARNESS1_INSTALL_ROOT", "zig-out");
    run.step.dependOn(credentials);
    step.dependOn(&run.step);
    return run;
}
