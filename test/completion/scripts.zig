//! End-to-end checks for the completion module: each shell generator
//! emits the program name, calls back to `__complete`, and the
//! `__complete` runtime returns subcommand and flag candidates with
//! the expected directive trailer.

const std = @import("std");
const zobra = @import("zobra");
const completion = @import("zobra-completion");

const Command = zobra.Command;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "bash completion: program name is interpolated" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "kt" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.genBashCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "complete -F __kt_get_completions kt") != null);
}

test "zsh completion: emits compdef header for the program" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "kt" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.genZshCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "#compdef kt") != null);
}

test "fish completion: registers handler" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "kt" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.genFishCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "function __kt_complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "complete -c kt") != null);
}

test "powershell completion: registers argument completer" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "kt" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.genPowerShellCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Register-ArgumentCompleter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-CommandName 'kt'") != null);
}

test "completion runtime: nested subcommand resolution" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();

    const subsys = try Command.init(gpa, .{ .use = "subsys" });
    try root.addCommand(subsys);
    try subsys.addCommand(try Command.init(gpa, .{ .use = "alpha", .short = "Alpha", .run_e = noopRun }));
    try subsys.addCommand(try Command.init(gpa, .{ .use = "beta", .short = "Beta", .run_e = noopRun }));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{ "subsys", "" }, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha\tAlpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beta\tBeta") != null);
}

test "completion runtime: flag-name candidates when token starts with --" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var verbose: bool = false;
    var quiet: bool = false;
    try root.flags().boolVarP(&verbose, "verbose", 'v', false, "Verbose output");
    try root.flags().boolVarP(&quiet, "quiet", 'q', false, "Quiet output");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{"--v"}, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "--verbose\tVerbose output") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--quiet") == null);
}

test "completion runtime: respects valid_args list" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "tool",
        .valid_args = &.{ "alpha", "beta", "gamma" },
        .run_e = noopRun,
    });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{"a"}, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beta") == null);
}

test "completion runtime: hidden subcommand excluded" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "visible", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "secret", .hidden = true, .run_e = noopRun }));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{""}, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret") == null);
}

test "completion runtime: directive trailer is :4 (NoFileComp) when emitting candidates" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "alpha", .run_e = noopRun }));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{""}, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, out, ":4\n"));
}

test "ShellCompDirective: format combines flags" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const D = completion.ShellCompDirective;
    try D.format(D.NoSpace | D.NoFileComp | D.KeepOrder, &w);
    try std.testing.expectEqualStrings(":38", w.buffered());
}

test "completion: installCompletionCommand wires up shell subcommands plus __complete" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();

    try completion.installCompletionCommand(root, .{});
    const c = root.findChildByNameOrAlias("completion") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c.findChildByNameOrAlias("bash") != null);
    try std.testing.expect(c.findChildByNameOrAlias("zsh") != null);
    try std.testing.expect(c.findChildByNameOrAlias("fish") != null);
    try std.testing.expect(c.findChildByNameOrAlias("powershell") != null);

    const cc = root.findChildByNameOrAlias("__complete") orelse return error.TestUnexpectedResult;
    try std.testing.expect(cc.hidden);
}

test "completion: end-to-end via execute() through __complete subcommand" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "kt" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .short = "List items", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "create", .short = "Create item", .run_e = noopRun }));
    try completion.installCompletionCommand(root, .{});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    root.setOut(&aw.writer);
    try root.execute(&.{ "__complete", "li" }, null);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "list\tList items") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "create") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, ":4\n"));
}

test "completion: bash subcommand prints bash script through configured writer" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "kt" });
    defer root.deinit();
    try completion.installCompletionCommand(root, .{});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    root.setOut(&aw.writer);
    try root.execute(&.{ "completion", "bash" }, null);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "complete -F __kt_get_completions kt") != null);
}

test "completion runtime: bare '-' lists every non-hidden long flag" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var verbose: bool = false;
    var quiet: bool = false;
    try root.flags().boolVarP(&verbose, "verbose", 'v', false, "Verbose");
    try root.flags().boolVarP(&quiet, "quiet", 'q', false, "Quiet");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{"-"}, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--quiet") != null);
}

test "completion runtime: '--flag=' is treated as a value request — emits no flag candidates" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var verbose: bool = false;
    try root.flags().boolVarP(&verbose, "verbose", 'v', false, "Verbose");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{"--verbose="}, &aw.writer);
    const out = aw.writer.buffered();
    // No `--verbose` candidate; shell falls through to default
    // file-completion behaviour via the directive.
    try std.testing.expect(std.mem.indexOf(u8, out, "--verbose") == null);
    try std.testing.expectEqualStrings(":4\n", out);
}

test "completion runtime: tokens after '--' are positional — no flag candidates emitted" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var xenon: bool = false;
    try root.flags().boolVarP(&xenon, "xenon", 'x', false, "X");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{ "--", "-x" }, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "--xenon") == null);
}

test "completion runtime: empty argv emits root subcommands" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .short = "Greet", .run_e = noopRun }));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completion.completeCommand(gpa, root, &.{}, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "greet") != null);
}

test "installCompletionCommand: disable_default_cmd skips `completion` but keeps `__complete`" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try completion.installCompletionCommand(root, .{ .disable_default_cmd = true });

    try std.testing.expect(root.findChildByNameOrAlias("completion") == null);
    try std.testing.expect(root.findChildByNameOrAlias("__complete") != null);
}

test "installCompletionCommand: hidden_default_cmd marks `completion` hidden" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try completion.installCompletionCommand(root, .{ .hidden_default_cmd = true });

    const c = root.findChildByNameOrAlias("completion") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c.hidden);
}
