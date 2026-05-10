//! Integration test: multi-level command tree with persistent flags
//! at every level, exercising effective-schema lookup, alias resolution,
//! and the apply path through nested subcommands.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");

fn noopRun(_: *zobra.Command, _: []const []const u8) anyerror!void {}

test "three-level tree: root → mid → leaf with persistent flags" {
    const gpa = testing.allocator;

    const root = try zobra.Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();

    const mid = try zobra.Command.init(gpa, .{ .use = "section", .aliases = &.{"sec"} });
    try root.addCommand(mid);

    const leaf = try zobra.Command.init(gpa, .{ .use = "act", .run_e = noopRun });
    try mid.addCommand(leaf);

    var rootflag: []const u8 = "";
    try root.persistentFlags().stringVarP(&rootflag, "from-root", 'r', "", "");

    var midflag: bool = false;
    try mid.persistentFlags().boolVarP(&midflag, "from-mid", 'm', false, "");

    var leafflag: i64 = 0;
    try leaf.flags().intVarP(&leafflag, "from-leaf", 'l', 0, "");

    // Use the alias for `section` and exercise all three flag levels.
    try root.execute(&.{ "sec", "act", "--from-root=R", "-m", "--from-leaf=42" }, null);

    try testing.expectEqualStrings("R", rootflag);
    try testing.expect(midflag);
    try testing.expectEqual(@as(i64, 42), leafflag);
}

test "subcommand falls through when arg doesn't match a child" {
    const gpa = testing.allocator;
    const root = try zobra.Command.init(gpa, .{ .use = "tool", .args = zobra.args.arbitrary, .run_e = noopRun });
    defer root.deinit();
    try root.addCommand(try zobra.Command.init(gpa, .{ .use = "greet", .run_e = noopRun }));

    // "stranger" doesn't match any child; `tool` runs and "stranger" is positional.
    try root.execute(&.{ "stranger", "alice" }, null);
}

test "persistent flag set on parent is required from child" {
    const gpa = testing.allocator;
    const root = try zobra.Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();

    var input: []const u8 = "";
    try root.persistentFlags().stringVarP(&input, "input", 'i', "", "");
    try root.markFlagRequired("input");

    const child = try zobra.Command.init(gpa, .{ .use = "go", .run_e = noopRun });
    try root.addCommand(child);

    var diag: zobra.Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.RequiredFlagMissing, root.execute(&.{"go"}, &diag));

    try root.execute(&.{ "go", "--input", "/tmp/x" }, null);
    try testing.expectEqualStrings("/tmp/x", input);
}

test "unknown subcommand falls back to root with arbitrary args" {
    // Without an explicit args validator and no matching subcommand,
    // cobra would error with "unknown command"; zobra's behaviour
    // depends on the validator. We just verify findCommand falls back.
    const gpa = testing.allocator;
    const root = try zobra.Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try zobra.Command.init(gpa, .{ .use = "known", .run_e = noopRun }));

    const found = try root.findCommand(gpa, &.{ "unknown-sub", "x" });
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("tool", found.cmd.commandName());
    try testing.expectEqual(@as(usize, 2), found.remaining.len);
}
