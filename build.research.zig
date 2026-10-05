// Targets only a developer of this project runs: the scratch programs under
// research, and the Python type check. They live here rather than in
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
const library = @import("build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = library.harnessModule(b, target);

    const credentials = library.installOmpKeys(b);

    const playground_exe = b.addExecutable(.{
        .name = "deepseek_playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/deepseek_playground.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, playground_exe, &credentials.step, "deepseek_playground", "Run the DeepSeek playground");

    // `judge` is one program and not a library on purpose — see its header.
    const judge_exe = b.addExecutable(.{
        .name = "zhengjian_judger",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/classifier-test/judger.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, judge_exe, &credentials.step, "judge", "Judge one answer against a rubric");

    const search_exe = b.addExecutable(.{
        .name = "zhengjian_search",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/classifier-test/search.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
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
    run_search.setEnvironmentVariable("RUN1_INSTALL_ROOT", "zig-out");
    run_search.step.dependOn(&credentials.step);
    search_step.dependOn(&run_search.step);

    // Rewrites src/remote/lithos_models.zig in place, which the library's build
    // then compiles as ordinary source — installation does not depend on
    // generation.
    const lithos_models_exe = b.addExecutable(.{
        .name = "lithos_models_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/lithos/lithos_models_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, lithos_models_exe, &credentials.step, "lithos_models", "Regenerate src/remote/lithos_models.zig from GET /v1/models");

    const lithos_probe_exe = b.addExecutable(.{
        .name = "lithos_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/lithos/lithos_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, lithos_probe_exe, &credentials.step, "lithos_probe", "Probe the per-model constraints of the LithosAI roster");

    const lithos_media_exe = b.addExecutable(.{
        .name = "lithos_media_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/lithos/lithos_media_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, lithos_media_exe, &credentials.step, "lithos_media", "Probe how LithosAI carries image and video input");

    const lithos_strict_exe = b.addExecutable(.{
        .name = "lithos_strict_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/lithos/lithos_strict_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, lithos_strict_exe, &credentials.step, "lithos_strict", "Probe whether LithosAI enforces strict tool schemas");

    const lithos_roles_exe = b.addExecutable(.{
        .name = "lithos_roles_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/lithos/lithos_roles_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, lithos_roles_exe, &credentials.step, "lithos_roles", "Probe the message and role shapes LithosAI accepts");

    const lithos_sysdev_exe = b.addExecutable(.{
        .name = "lithos_sysdev_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/lithos/lithos_sysdev_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, lithos_sysdev_exe, &credentials.step, "lithos_sysdev", "Probe how DeepSeek-on-LithosAI treats system versus developer turns");

    // Ties the harness's transport to the system libcurl for the first time:
    // if this does not negotiate h2, nothing in `src/` will. Zig 0.17 has no
    // `@cImport`, so the header reaches Zig through translate-c.
    const curl_translate = b.addTranslateC(.{
        .root_source_file = b.path("research/curl_shim.c"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // `/usr/local/include` precedes `/usr/include` in the default search path,
    // and a stale curl 7.79.1 header tree lives there; the system tree wins
    // only if it is named first.
    curl_translate.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    curl_translate.linkSystemLibrary("curl", .{});

    const libcurl_probe_exe = b.addExecutable(.{
        .name = "libcurl_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/libcurl_probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "curl", .module = curl_translate.createModule() },
            },
        }),
    });
    libcurl_probe_exe.root_module.linkSystemLibrary("curl", .{});
    const libcurl_step = b.step("libcurl_probe", "Prove libcurl links from Zig and negotiates HTTP/2");
    const run_libcurl = b.addRunArtifact(libcurl_probe_exe);
    run_libcurl.addPassthruArgs();
    run_libcurl.setCwd(b.path("."));
    libcurl_step.dependOn(&run_libcurl.step);

    // Times `std.http.Client`'s HTTP/1.1 under concurrency, for comparison with
    // curl's h1 on the same endpoint.
    const zig_h1_bench_exe = b.addExecutable(.{
        .name = "zig_h1_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/zig_h1_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const curl_smoke_exe = b.addExecutable(.{
        .name = "curl_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/curl_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    const curl_smoke_step = b.step("curl_smoke", "Smoke-test the libcurl transport");
    const run_curl_smoke = b.addRunArtifact(curl_smoke_exe);
    run_curl_smoke.setCwd(b.path("."));
    curl_smoke_step.dependOn(&run_curl_smoke.step);

    const cache_probe_exe = b.addExecutable(.{
        .name = "cache_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/cache_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    _ = addRunStep(b, cache_probe_exe, &credentials.step, "cache_probe", "Measure whether prompt caching needs a fixed prefix");

    const zig_h1_step = b.step("zig_h1_bench", "Time N concurrent HTTP/1.1 requests from std.http.Client");
    const run_zig_h1 = b.addRunArtifact(zig_h1_bench_exe);
    run_zig_h1.addPassthruArgs();
    run_zig_h1.setCwd(b.path("."));
    zig_h1_step.dependOn(&run_zig_h1.step);

    // Attributes every part of every omp session transcript to a named
    // feature. Reads only the local session store, so it needs neither a key
    // nor a network.
    const omp_features_exe = b.addExecutable(.{
        .name = "omp_features",
        .root_module = b.createModule(.{
            .root_source_file = b.path("research/omp-features/features.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "run1", .module = mod },
            },
        }),
    });
    const omp_features_step = b.step("omp_features", "Attribute every part of every omp session to a named feature");
    const run_omp_features = b.addRunArtifact(omp_features_exe);
    run_omp_features.addPassthruArgs();
    run_omp_features.setCwd(b.path("."));
    omp_features_step.dependOn(&run_omp_features.step);

    // `ty` is not vendored, so this step needs it on the PATH: `uv tool install
    // ty` (or pipx, or `pip install ty`). `ty.toml` beside the client says what
    // is checked and how strictly, and ty reads it from the working directory,
    // which is therefore the client's own.
    const check_python_step = b.step("check_python", "Type-check the Python client under research/python");
    const ty_check = b.addSystemCommand(&.{ "ty", "check" });
    ty_check.setCwd(b.path("research/python"));
    check_python_step.dependOn(&ty_check.step);
}

// Registers `exe` as a top-level step that runs it with whatever follows `--`
// on the command line.
//
// A scratch program runs out of the build cache, not the install tree, so it
// needs to be told where that tree is: `RUN1_INSTALL_ROOT` is the default
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
    run.setEnvironmentVariable("RUN1_INSTALL_ROOT", "zig-out");
    run.step.dependOn(credentials);
    step.dependOn(&run.step);
    return run;
}
