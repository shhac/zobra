const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zobra_mod = b.addModule("zobra", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Satellite module: doc generators (markdown/yaml/rest/man).
    // Lives behind a separate import so consumers who don't need
    // doc generation pay no compile cost for them.
    const zobra_doc_mod = b.addModule("zobra-doc", .{
        .root_source_file = b.path("src/doc/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zobra", .module = zobra_mod },
        },
    });

    // Satellite module: shell completion (bash/zsh/fish/pwsh) plus the
    // __complete runtime callback. Same shape as zobra-doc — separate
    // import keeps unused-on-most-CLIs payload out of the core module.
    const zobra_completion_mod = b.addModule("zobra-completion", .{
        .root_source_file = b.path("src/completion/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zobra", .module = zobra_mod },
        },
    });

    // The demo binary lives under `examples/` (outside `src/`) so it
    // never ships to consumers — build.zig.zon's `paths` only includes
    // `src/` plus build/license/readme. The example exists for `zig build run`
    // dogfooding and as the target of the E2E smoke tests.
    const example_exe = b.addExecutable(.{
        .name = "zobra-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zobra", .module = zobra_mod },
            },
        }),
    });
    b.installArtifact(example_exe);

    const run_step = b.step("run", "Run the example");
    const run_cmd = b.addRunArtifact(example_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = zobra_mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const doc_tests = b.addTest(.{ .root_module = zobra_doc_mod });
    const run_doc_tests = b.addRunArtifact(doc_tests);

    const completion_tests = b.addTest(.{ .root_module = zobra_completion_mod });
    const run_completion_tests = b.addRunArtifact(completion_tests);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zobra", .module = zobra_mod },
            .{ .name = "zobra-doc", .module = zobra_doc_mod },
            .{ .name = "zobra-completion", .module = zobra_completion_mod },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_doc_tests.step);
    test_step.dependOn(&run_completion_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // E2E smoke tests — spawn the built `zobra-example` binary as a
    // subprocess and assert on stdout/stderr/exit. Wired as a separate
    // `zig build test-e2e` step so it can be skipped in environments
    // where the binary can't be exec'd (some CI sandboxes). The test
    // module is given the absolute install-prefix path to the binary
    // via the `build_options` import.
    const e2e_opts = b.addOptions();
    const bin_install_path = b.fmt("{s}/bin/zobra-example", .{b.install_prefix});
    e2e_opts.addOption([]const u8, "bin_path", bin_install_path);

    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("examples/hello/test_e2e.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = e2e_opts.createModule() },
        },
    });
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    run_e2e_tests.step.dependOn(b.getInstallStep()); // ensure binary exists

    const e2e_step = b.step("test-e2e", "Run end-to-end smoke tests against the demo binary");
    e2e_step.dependOn(&run_e2e_tests.step);

    // The default `test` step doesn't include E2E (subprocess spawning
    // is heavier and depends on the install step). Run both with
    // `zig build test test-e2e`.
}
