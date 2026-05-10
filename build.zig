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

    const example_exe = b.addExecutable(.{
        .name = "zobra-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/hello/main.zig"),
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

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zobra", .module = zobra_mod },
            .{ .name = "zobra-doc", .module = zobra_doc_mod },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_doc_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
