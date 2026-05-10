//! Command tests — pulled out of the inline `test "..."` blocks at the
//! bottom of src/core/command/command.zig per the file-decomposition
//! pass. Tests cover lifecycle, addCommand, findCommand, hooks, args
//! validators, flag groups, --help, --version, disable_flag_parsing,
//! allow_unknown_flags, suggestion path, parse-error wording, and the
//! pure firstPositionalArgvIndex / argvWithout helpers.
//!
//! Public-API surface only — exercises through `zobra.Command` rather
//! than via the underlying `command_mod` import.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const Command = zobra.Command;
const Diagnostic = zobra.Diagnostic;
const args_mod = zobra.args;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

// ---- shared test fixtures -----------------------------------------------

var captured_hooks: std.ArrayListUnmanaged([]const u8) = .empty;
var captured_allocator: std.mem.Allocator = undefined;

const HookFnE = *const fn (cmd: *Command, args: []const []const u8) anyerror!void;

fn recordHook(comptime label: []const u8) HookFnE {
    return struct {
        fn run(_: *Command, _: []const []const u8) anyerror!void {
            try captured_hooks.append(captured_allocator, label);
        }
    }.run;
}

// ---- lifecycle ----------------------------------------------------------

test "Command: init/deinit roundtrip" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{ .use = "myapp", .short = "test app" });
    defer cmd.deinit();
    try testing.expectEqualStrings("myapp", cmd.use);
    try testing.expectEqualStrings("myapp", cmd.commandName());
}

test "Command: addCommand transfers ownership" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    const child = try Command.init(gpa, .{ .use = "child" });
    try root.addCommand(child);
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expect(child.parent == root);
}

test "Command: addCommand rejects already-parented child (memory-safety)" {
    const gpa = testing.allocator;
    const root_a = try Command.init(gpa, .{ .use = "a" });
    defer root_a.deinit();
    const root_b = try Command.init(gpa, .{ .use = "b" });
    defer root_b.deinit();
    const child = try Command.init(gpa, .{ .use = "child" });
    try root_a.addCommand(child); // ownership transferred to root_a
    // root_b.addCommand(child) would put `child` in two children lists —
    // double-free hazard on deinit. Must error.
    try testing.expectError(error.AlreadyParented, root_b.addCommand(child));
}

test "Command: addCommand rejects self as child" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try testing.expectError(error.SelfParent, root.addCommand(root));
}

test "Command: argsLenAtDash exposes positionals-before-dash" {
    const gpa = testing.allocator;
    const Capture = struct {
        var value: ?usize = null;
        fn run(cmd: *Command, _: []const []const u8) anyerror!void {
            value = cmd.argsLenAtDash();
        }
    };
    Capture.value = null;

    const root = try Command.init(gpa, .{
        .use = "tool",
        .args = args_mod.arbitrary,
        .run_e = Capture.run,
    });
    defer root.deinit();
    try root.execute(&.{ "a", "b", "--", "c", "d" }, null);
    try testing.expectEqual(@as(?usize, 2), Capture.value);
}

// ---- findCommand --------------------------------------------------------

test "Command: findCommand resolves children by name" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet [target]" }));

    const found = try root.findCommand(gpa, &.{ "greet", "alice" }, null);
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("greet", found.cmd.commandName());
    try testing.expectEqual(@as(usize, 1), found.remaining.len);
    try testing.expectEqualStrings("alice", found.remaining[0]);
}

test "Command: findCommand resolves by alias" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .aliases = &.{ "ls", "l" } }));

    const found = try root.findCommand(gpa, &.{"ls"}, null);
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("list", found.cmd.commandName());
    try testing.expectEqual(@as(usize, 0), found.remaining.len);
}

test "Command: findCommand falls back to self when no child matches" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet" }));

    const found = try root.findCommand(gpa, &.{ "stranger", "alice" }, null);
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("root", found.cmd.commandName());
    try testing.expectEqual(@as(usize, 2), found.remaining.len);
}

test "Command: suggestionsForCommand returns close subcommands" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .run_e = noopRun }));

    const out = try root.suggestionsForCommand(gpa, "lst");
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("list", out[0]);
}

// ---- persistent flags ---------------------------------------------------

test "Command: persistent flag is visible to a child" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    var name: []const u8 = "world";
    try root.persistentFlags().stringVarP(&name, "name", 'n', "world", "");

    const child = try Command.init(gpa, .{ .use = "greet", .run_e = noopRun });
    try root.addCommand(child);

    try root.execute(&.{ "greet", "--name", "alice" }, null);
    try testing.expectEqualStrings("alice", name);
}

// ---- hook chain ---------------------------------------------------------

test "Command: hook chain fires in cobra order" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "root",
        .persistent_pre_run_e = recordHook("rootPersistentPre"),
        .persistent_post_run_e = recordHook("rootPersistentPost"),
    });
    defer root.deinit();

    const child = try Command.init(gpa, .{
        .use = "child",
        .pre_run_e = recordHook("childPre"),
        .run_e = recordHook("childRun"),
        .post_run_e = recordHook("childPost"),
    });
    try root.addCommand(child);

    captured_hooks = .empty;
    defer captured_hooks.deinit(gpa);
    captured_allocator = gpa;
    try root.execute(&.{"child"}, null);

    const expected = [_][]const u8{
        "rootPersistentPre",
        "childPre",
        "childRun",
        "childPost",
        "rootPersistentPost",
    };
    try testing.expectEqual(expected.len, captured_hooks.items.len);
    for (expected, 0..) |want, i| {
        try testing.expectEqualStrings(want, captured_hooks.items[i]);
    }
}

test "Command: hook chain — first persistent ancestor wins (non-traverse)" {
    const gpa = testing.allocator;
    const Hooks = struct {
        var fires: std.ArrayListUnmanaged([]const u8) = .empty;
        var alloc: std.mem.Allocator = undefined;
        fn rootHook(_: *Command, _: []const []const u8) anyerror!void {
            try fires.append(alloc, "root");
        }
        fn childHook(_: *Command, _: []const []const u8) anyerror!void {
            try fires.append(alloc, "child");
        }
    };
    Hooks.fires = .empty;
    Hooks.alloc = gpa;
    defer Hooks.fires.deinit(gpa);

    const root = try Command.init(gpa, .{ .use = "root", .persistent_pre_run_e = Hooks.rootHook });
    defer root.deinit();
    const child = try Command.init(gpa, .{
        .use = "child",
        .persistent_pre_run_e = Hooks.childHook,
        .run_e = noopRun,
    });
    try root.addCommand(child);
    try root.execute(&.{"child"}, null);

    try testing.expectEqual(@as(usize, 1), Hooks.fires.items.len);
    try testing.expectEqualStrings("child", Hooks.fires.items[0]);
}

// ---- args validators ----------------------------------------------------

test "Command: args validator rejects too few" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "root",
        .args = args_mod.minimumN(1),
        .run_e = noopRun,
    });
    defer root.deinit();

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.ArgsValidationFailed, root.execute(&.{}, &diag));
    try testing.expectEqualStrings("requires at least 1 arg(s), only received 0", diag.message.?);
}

test "Command: noArgs at depth includes command path in wording" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    const child = try Command.init(gpa, .{
        .use = "greet",
        .args = args_mod.noArgs,
        .run_e = noopRun,
    });
    try root.addCommand(child);

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.ArgsValidationFailed, root.execute(&.{ "greet", "extra" }, &diag));
    try testing.expectEqualStrings("unknown command \"extra\" for \"tool greet\"", diag.message.?);
}

// ---- required flags + flag groups --------------------------------------

test "Command: required flag enforcement" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root", .run_e = noopRun });
    defer root.deinit();
    var name: []const u8 = "";
    try root.flags().stringVarP(&name, "name", 'n', "", "");
    try root.markFlagRequired("name");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.RequiredFlagMissing, root.execute(&.{}, &diag));

    try root.execute(&.{ "--name", "alice" }, null);
    try testing.expectEqualStrings("alice", name);
}

test "Command: markFlagsMutuallyExclusive errors if both set" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var a: bool = false;
    var b: bool = false;
    try root.flags().boolVarP(&a, "json", 0, false, "");
    try root.flags().boolVarP(&b, "yaml", 0, false, "");
    try root.markFlagsMutuallyExclusive(&.{ "json", "yaml" });

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.FlagGroupViolation, root.execute(&.{ "--json", "--yaml" }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "if any flags in the group [json yaml] are set none of the others can be") != null);

    var a2: bool = false;
    var b2: bool = false;
    const root2 = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root2.deinit();
    try root2.flags().boolVarP(&a2, "json", 0, false, "");
    try root2.flags().boolVarP(&b2, "yaml", 0, false, "");
    try root2.markFlagsMutuallyExclusive(&.{ "json", "yaml" });
    try root2.execute(&.{"--json"}, null);
}

test "Command: markFlagsRequiredTogether errors on partial set" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var u: []const u8 = "";
    var p: []const u8 = "";
    try root.flags().stringVarP(&u, "user", 0, "", "");
    try root.flags().stringVarP(&p, "password", 0, "", "");
    try root.markFlagsRequiredTogether(&.{ "user", "password" });

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.FlagGroupViolation, root.execute(&.{ "--user", "alice" }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "if any flags in the group [password user] are set they must all be set; missing [password]") != null);

    const root2 = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root2.deinit();
    var user2: []const u8 = "";
    var pass2: []const u8 = "";
    try root2.flags().stringVarP(&user2, "user", 0, "", "");
    try root2.flags().stringVarP(&pass2, "password", 0, "", "");
    try root2.markFlagsRequiredTogether(&.{ "user", "password" });
    try root2.execute(&.{ "--user", "alice", "--password", "secret" }, null);
}

test "Command: markFlagsOneRequired errors when none set" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var a: bool = false;
    var b: bool = false;
    try root.flags().boolVarP(&a, "json", 0, false, "");
    try root.flags().boolVarP(&b, "yaml", 0, false, "");
    try root.markFlagsOneRequired(&.{ "json", "yaml" });

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.FlagGroupViolation, root.execute(&.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "at least one of the flags in the group [json yaml] is required") != null);
}

// ---- --help / --version -------------------------------------------------

test "Command: --help prints help to provided writer" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "tool",
        .short = "a tool",
        .run_e = noopRun,
    });
    defer root.deinit();
    var name: []const u8 = "world";
    try root.flags().stringVarP(&name, "name", 'n', "world", "who to greet");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{"--help"}, .{ .out_writer = &aw.writer });

    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "Usage:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  -n, --name string") != null);
    try testing.expectEqualStrings("world", name);
}

test "Command: --help with no out_writer returns HelpRequested" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    try testing.expectError(error.HelpRequested, root.execute(&.{"--help"}, null));
}

test "Command: -h shorthand triggers help" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{"-h"}, .{ .out_writer = &aw.writer });
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "Usage:") != null);
}

test "Command: command without run prints help even without --help" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .short = "no run defined" });
    defer root.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{}, .{ .out_writer = &aw.writer });
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "Usage:") != null);
}

test "Command: --version prints version banner" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .version = "1.2.3", .run_e = noopRun });
    defer root.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{"--version"}, .{ .out_writer = &aw.writer });
    try testing.expectEqualStrings("tool version 1.2.3\n", aw.writer.buffered());
}

test "Command: --version with no out_writer returns VersionRequested" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .version = "9.9", .run_e = noopRun });
    defer root.deinit();
    try testing.expectError(error.VersionRequested, root.execute(&.{"--version"}, null));
}

// ---- disable_flag_parsing / allow_unknown_flags ------------------------

test "Command: disable_flag_parsing passes argv through verbatim" {
    const gpa = testing.allocator;
    const RunCtx = struct {
        var captured_args: ?[]const []const u8 = null;
        fn run(_: *Command, args: []const []const u8) anyerror!void {
            captured_args = args;
        }
    };

    const root = try Command.init(gpa, .{
        .use = "proxy",
        .disable_flag_parsing = true,
        .run_e = RunCtx.run,
    });
    defer root.deinit();
    try root.execute(&.{ "--unknown=foo", "-x", "--bar" }, null);
    try testing.expect(RunCtx.captured_args.?.len == 3);
    try testing.expectEqualStrings("--unknown=foo", RunCtx.captured_args.?[0]);
}

test "Command: allow_unknown_flags swallows unknowns" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "tool",
        .allow_unknown_flags = true,
        .run_e = noopRun,
    });
    defer root.deinit();
    var n: i64 = 0;
    try root.flags().intVarP(&n, "count", 0, 0, "");
    try root.execute(&.{ "--count=5", "--mystery=zzz" }, null);
    try testing.expectEqual(@as(i64, 5), n);
}

// ---- diagnostic wording -------------------------------------------------

test "Command: did-you-mean suggestion on close-by flag" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var name: []const u8 = "";
    try root.flags().stringVarP(&name, "name", 'n', "", "");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.UnknownFlag, root.execute(&.{ "--nmae", "x" }, &diag));
    try testing.expect(diag.suggestion != null);
    try testing.expectEqualStrings("did you mean --name?", diag.suggestion.?);
    try testing.expectEqualStrings("unknown flag: --nmae", diag.message.?);
}

test "Command: unknown shorthand renders pflag wording with the group suffix" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var a: bool = false;
    try root.flags().boolVarP(&a, "alpha", 'a', false, "");

    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    try testing.expectError(error.UnknownFlag, root.execute(&.{"-axyz"}, &d));
    try testing.expectEqualStrings("unknown shorthand flag: \"x\" in -xyz", d.message.?);
}

test "Command: parse error wordings render onto diag.message" {
    const gpa = testing.allocator;

    {
        const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
        defer root.deinit();
        var n: i64 = 0;
        try root.flags().intVarP(&n, "retries", 0, 0, "");
        var d: Diagnostic = .{};
        defer d.deinit(gpa);
        try testing.expectError(error.MissingValue, root.execute(&.{"--retries"}, &d));
        try testing.expectEqualStrings("flag needs an argument: --retries", d.message.?);
    }

    {
        const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
        defer root.deinit();
        var d: Diagnostic = .{};
        defer d.deinit(gpa);
        try testing.expectError(error.BadFlagSyntax, root.execute(&.{"---bad"}, &d));
        try testing.expectEqualStrings("bad flag syntax: ---bad", d.message.?);
    }

    {
        const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
        defer root.deinit();
        var n: i64 = 0;
        try root.flags().intVarP(&n, "retries", 'r', 0, "");
        var d: Diagnostic = .{};
        defer d.deinit(gpa);
        try testing.expectError(error.TypeCoercionFailed, root.execute(&.{"--retries=foo"}, &d));
        try testing.expectEqualStrings(
            "invalid argument \"foo\" for \"-r, --retries\" flag: strconv.ParseInt: parsing \"foo\": invalid syntax",
            d.message.?,
        );
    }
}
