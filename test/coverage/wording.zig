//! Wording / fixture-shape tests. Lock in pflag-byte-identical wording
//! for paths that would silently regress under refactoring.
//!
//! Lens 5 findings: #4 (--no-foo end-to-end), #6 (-h collision),
//! #7 (findCommand attached-value-equals-child), #13 (help-output
//! byte-oracle), #16 (repeated-char findCharSlice).

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const Command = zobra.Command;
const Diagnostic = zobra.Diagnostic;
const args_mod = zobra.args;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

// ---- --no-foo when foo isn't a known boolean ---------------------------

test "wording: --no-bar where bar is not registered → unknown flag --no-bar" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.UnknownFlag, root.execute(&.{"--no-bar"}, &diag));
    try testing.expectEqualStrings("unknown flag: --no-bar", diag.message.?);
}

test "wording: --no-foo where foo is a string flag → unknown flag --no-foo" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var s: []const u8 = "";
    try root.flags().stringVarP(&s, "foo", 0, "", "");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    // foo is registered but not a boolean; parser emits a regular long
    // for "no-foo", flag layer rejects.
    try testing.expectError(error.UnknownFlag, root.execute(&.{"--no-foo"}, &diag));
    try testing.expectEqualStrings("unknown flag: --no-foo", diag.message.?);
}

// ---- -h shorthand collision --------------------------------------------

test "wording: user-bound -h takes precedence; --help still triggers help" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    // User binds -h to their own boolean ("host" flag).
    var host: bool = false;
    try root.flags().boolVarP(&host, "host", 'h', false, "host mode");

    // -h triggers their flag, NOT help.
    try root.execute(&.{"-h"}, null);
    try testing.expect(host);

    // --help still works (long form, auto-injected).
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const root2 = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root2.deinit();
    var host2: bool = false;
    try root2.flags().boolVarP(&host2, "host", 'h', false, "host mode");
    try root2.executeWith(&.{"--help"}, .{ .out_writer = &aw.writer });
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "Usage:") != null);
    try testing.expect(!host2); // -h flag NOT triggered
}

// ---- findCommand: value-equals-child-name regression -------------------

test "findCommand: --target=greet does not consume child named greet" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    var target: []const u8 = "";
    try root.persistentFlags().stringVarP(&target, "target", 't', "", "");

    const greet = try Command.init(gpa, .{ .use = "greet", .run_e = noopRun });
    try root.addCommand(greet);

    // --target=greet has the value attached; the FOLLOWING `greet`
    // is the actual subcommand.
    try root.execute(&.{ "--target=greet", "greet" }, null);
    try testing.expectEqualStrings("greet", target);
}

test "findCommand: --target greet does not consume child named greet" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    var target: []const u8 = "";
    try root.persistentFlags().stringVarP(&target, "target", 't', "", "");

    const greet = try Command.init(gpa, .{ .use = "greet", .run_e = noopRun });
    try root.addCommand(greet);

    // --target consumes the next argv slot (= "greet") as its value;
    // the second "greet" is the subcommand.
    try root.execute(&.{ "--target", "greet", "greet" }, null);
    try testing.expectEqualStrings("greet", target);
}

// ---- help-output byte-oracle -------------------------------------------

test "help: full byte-for-byte oracle for a representative leaf command" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "greet [target]",
        .short = "Print a greeting",
        .long = "Print a friendly greeting to the named target.",
        .aliases = &.{ "g", "hello" },
        .example = "  tool greet alice",
        .run_e = noopRun,
    });
    defer cmd.deinit();

    var name: []const u8 = "world";
    try cmd.flags().stringVarP(&name, "name", 'n', "world", "who to greet");

    // Trigger lazy --help registration via executeWith with a fixed
    // writer, so the rendered help below includes the auto-injected
    // help flag (matching what users actually see).
    var fbw_buf: [4096]u8 = undefined;
    var fbw: std.Io.Writer = .fixed(&fbw_buf);
    try cmd.executeWith(&.{"--help"}, .{ .out_writer = &fbw });
    const out = fbw.buffered();

    const expected =
        \\Print a friendly greeting to the named target.
        \\
        \\Usage:
        \\  greet [target] [flags]
        \\
        \\Aliases:
        \\  greet, g, hello
        \\
        \\Examples:
        \\  tool greet alice
        \\
        \\Flags:
        \\  -h, --help         help for greet
        \\  -n, --name string  who to greet (default "world")
        \\
    ;
    try testing.expectEqualStrings(expected, out);
}

test "help: parent with subcommands prints in cobra-byte-identical column shape" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .short = "a tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .short = "Print a greeting", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .short = "List things", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "version", .short = "Show version", .run_e = noopRun }));

    const out = try root.helpString(gpa);
    defer gpa.free(out);

    // Padding to min-name-padding=11 (cobra's default minNamePadding).
    // "greet" (5 chars) + 7 spaces + "Print a greeting" → padded to 12.
    try testing.expect(std.mem.indexOf(u8, out, "  greet       Print a greeting\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  list        List things\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  version     Show version\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Use \"tool [command] --help\" for more information about a command.") != null);
}

// ---- repeated-char shorthand suffix ------------------------------------

test "wording: -aab where a is unknown — group suffix uses first match" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var b: bool = false;
    try root.flags().boolVarP(&b, "bb", 'b', false, "");

    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    // -a is unknown; pflag's wording uses the suffix from the point of
    // error. For "-aab", we encounter 'a' at position 1. Suffix = "aab".
    try testing.expectError(error.UnknownFlag, root.execute(&.{"-aab"}, &d));
    try testing.expectEqualStrings("unknown shorthand flag: \"a\" in -aab", d.message.?);
}
