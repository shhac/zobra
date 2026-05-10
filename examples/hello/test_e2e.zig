//! End-to-end smoke tests for the `zobra-example` demo binary.
//!
//! These spawn the actual built `zobra-example` executable as a
//! subprocess and assert on stdout / stderr / exit code. The goal is
//! to validate the full integration: argv → parser → command dispatch
//! → flag binding → hook chain → output. Unit tests cover the
//! library; these cover "does it actually wire up at the process
//! boundary?"
//!
//! Build wiring: `zig build test-e2e` runs these (the test step depends
//! on `examples_install` so the binary is built first).
//!
//! The binary path is passed in via the `bin` build option (defaults
//! to `zig-out/bin/zobra-example`).

const std = @import("std");

const bin_path_option = @import("build_options").bin_path;

fn runExample(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !std.process.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin_path_option);
    try argv.appendSlice(allocator, args);

    return std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
    });
}

fn freeResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

test "e2e: bare `greet` uses default --name" {
    const gpa = std.testing.allocator;
    const r = try runExample(gpa, &.{"greet"});
    defer freeResult(gpa, r);
    try std.testing.expectEqualStrings("hello, world\n", r.stdout);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

test "e2e: --name flag overrides default" {
    const gpa = std.testing.allocator;
    const r = try runExample(gpa, &.{ "--name=alice", "greet" });
    defer freeResult(gpa, r);
    try std.testing.expectEqualStrings("hello, alice\n", r.stdout);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

test "e2e: persistent flag works in any position" {
    const gpa = std.testing.allocator;
    // Persistent flag set AFTER the subcommand (cobra accepts both).
    const r = try runExample(gpa, &.{ "greet", "--name=bob" });
    defer freeResult(gpa, r);
    try std.testing.expectEqualStrings("hello, bob\n", r.stdout);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

test "e2e: positional argument overrides --name" {
    const gpa = std.testing.allocator;
    const r = try runExample(gpa, &.{ "greet", "carol" });
    defer freeResult(gpa, r);
    try std.testing.expectEqualStrings("hello, carol\n", r.stdout);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

test "e2e: short-flag clustering for count flag" {
    const gpa = std.testing.allocator;
    const r = try runExample(gpa, &.{ "-vv", "greet" });
    defer freeResult(gpa, r);
    try std.testing.expectEqualStrings("hello, world\nverbose=2\n", r.stdout);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

test "e2e: --help prints the help block (exit 0)" {
    const gpa = std.testing.allocator;
    const r = try runExample(gpa, &.{"--help"});
    defer freeResult(gpa, r);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a tiny zobra demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "greet") != null);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

test "e2e: unknown subcommand on a root with no Run prints help (cobra-correct)" {
    // Cobra behaviour: when an unknown name follows a root with no Run
    // handler, the dispatch falls back to printing root's help and
    // exits 0. Pinning the cobra-parity behaviour here.
    const gpa = std.testing.allocator;
    const r = try runExample(gpa, &.{"gret"});
    defer freeResult(gpa, r);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a tiny zobra demo") != null);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

test "e2e: unknown flag prints pflag-shape error + nonzero exit" {
    const gpa = std.testing.allocator;
    const r = try runExample(gpa, &.{ "greet", "--nope" });
    defer freeResult(gpa, r);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unknown flag: --nope") != null);
    try std.testing.expect(r.term == .exited and r.term.exited != 0);
}

test "e2e: too-many-args triggers the args validator" {
    const gpa = std.testing.allocator;
    // greet accepts at most 1 positional; two should fail.
    const r = try runExample(gpa, &.{ "greet", "a", "b" });
    defer freeResult(gpa, r);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "accepts at most") != null);
    try std.testing.expect(r.term == .exited and r.term.exited != 0);
}
