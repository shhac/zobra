//! Completion runtime — the `__complete` callback that the generated
//! shell scripts invoke to compute candidates.
//!
//! Wire format (matches cobra's completions.go):
//!   stdout: <line>\n<line>\n...:<directive>\n
//!   each <line> is `value\tdescription` (description optional).
//!   <directive> is the ShellCompDirective bitfield as decimal.

const std = @import("std");
const zobra = @import("zobra");
const directive_mod = @import("directive.zig");
const options_mod = @import("options.zig");

pub const Command = zobra.Command;
pub const ShellCompDirective = directive_mod.ShellCompDirective;
pub const CompletionOptions = options_mod.CompletionOptions;

/// Per-command callback returning positional-argument completions.
/// `cmd` is the resolved command; `args` is the positional args
/// already entered; `to_complete` is the partial token under cursor.
/// Returns (candidates, directive). Caller frees candidates.
pub const ValidArgsFunction = *const fn (
    cmd: *const Command,
    args: []const []const u8,
    to_complete: []const u8,
    allocator: std.mem.Allocator,
) anyerror!Completions;

/// Per-flag callback — same shape as ValidArgsFunction but for a
/// specific flag's value space.
pub const FlagCompletionFunction = *const fn (
    cmd: *const Command,
    args: []const []const u8,
    to_complete: []const u8,
    allocator: std.mem.Allocator,
) anyerror!Completions;

pub const Completions = struct {
    candidates: []const Candidate,
    directive: u32,

    pub const Candidate = struct {
        value: []const u8,
        description: []const u8 = "",
    };
};

/// Runtime entry point: walk argv to find the resolved subcommand
/// and the partial token to complete; emit candidates to `w` in the
/// cobra completion-protocol shape. Mirrors cobra.completionFunc.
///
/// argv shape: `[..., "__complete", <user-argv>...]` — cobra's
/// `__complete` subcommand strips the `__complete` token and
/// processes the rest. This function takes the rest directly.
pub fn completeCommand(
    allocator: std.mem.Allocator,
    root: *Command,
    argv: []const []const u8,
    w: *std.Io.Writer,
) !void {
    const to_complete = if (argv.len > 0) argv[argv.len - 1] else "";
    const earlier = if (argv.len > 0) argv[0 .. argv.len - 1] else &.{};

    // If `--` appeared earlier, subsequent tokens are positional-only;
    // flag-name candidates would be wrong. Cobra's bash V2 handler does
    // the same separation.
    const after_double_dash = sliceContains(earlier, "--");

    // Skip `--` when resolving the command — findCommand doesn't model
    // the pflag separator and would treat it as a command name.
    const command_argv = stripDoubleDash(earlier);
    const found = try root.findCommand(allocator, command_argv, null);
    defer allocator.free(found.remaining);
    const cmd = found.cmd;

    var candidates: std.ArrayListUnmanaged(Completions.Candidate) = .empty;
    defer candidates.deinit(allocator);
    var owned_values: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (owned_values.items) |v| allocator.free(v);
        owned_values.deinit(allocator);
    }

    // If the partial token contains `=`, the user is typing a flag value
    // (`--name=...`). Drop all candidates; we don't currently dispatch to
    // a flag-value completer, so emitting nothing with `:NoFileComp` lets
    // the shell fall through to file completion (a reasonable default
    // that matches cobra when no callback is set).
    const looks_like_flag_value = to_complete.len > 0 and to_complete[0] == '-' and std.mem.indexOfScalar(u8, to_complete, '=') != null;

    if (!looks_like_flag_value) {
        if (to_complete.len > 0 and to_complete[0] == '-' and !after_double_dash) {
            try collectFlagCandidates(cmd, to_complete, allocator, &candidates, &owned_values);
        } else {
            try collectSubcommandAndArgCandidates(cmd, to_complete, allocator, &candidates);
        }
    }

    for (candidates.items) |c| {
        if (c.description.len > 0) {
            try w.print("{s}\t{s}\n", .{ c.value, c.description });
        } else {
            try w.print("{s}\n", .{c.value});
        }
    }
    try ShellCompDirective.format(ShellCompDirective.NoFileComp, w);
    try w.writeByte('\n');
}

fn sliceContains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn stripDoubleDash(args: []const []const u8) []const []const u8 {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--")) return args[0..i];
    }
    return args;
}

fn collectSubcommandAndArgCandidates(
    cmd: *const Command,
    to_complete: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Completions.Candidate),
) !void {
    for (cmd.children.items) |child| {
        if (child.hidden) continue;
        const name = child.commandName();
        if (std.mem.eql(u8, name, "__complete")) continue;
        if (std.mem.eql(u8, name, "__completeNoDesc")) continue;
        if (std.mem.startsWith(u8, name, to_complete)) {
            try out.append(allocator, .{ .value = name, .description = child.short });
        }
    }
    for (cmd.valid_args) |v| {
        if (std.mem.startsWith(u8, v, to_complete)) {
            try out.append(allocator, .{ .value = v });
        }
    }
}

fn collectFlagCandidates(
    cmd: *const Command,
    to_complete: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Completions.Candidate),
    owned: *std.ArrayListUnmanaged([]const u8),
) !void {
    const prefix = if (std.mem.startsWith(u8, to_complete, "--")) to_complete[2..] else to_complete[1..];
    inline for (.{ "flags_set", "persistent_flags_set" }) |field| {
        const fset = &@field(cmd.*, field);
        for (fset.ordered.items) |f| {
            if (f.hidden) continue;
            if (std.mem.startsWith(u8, f.name, prefix)) {
                const value = try std.fmt.allocPrint(allocator, "--{s}", .{f.name});
                try owned.append(allocator, value);
                try out.append(allocator, .{ .value = value, .description = f.usage });
            }
        }
    }
}

/// Lazy-register a `completion [shell]` subcommand on the root, plus
/// the hidden `__complete` runtime subcommand. Idempotent — a second
/// call is a no-op. The auto-registered `completion` subcommand has
/// shell-specific children (bash/zsh/fish/powershell), each of which
/// generates its respective script when run. The hidden `__complete`
/// subcommand is what those generated scripts call back into.
///
/// Toggles via `CompletionOptions`:
/// - `disable_default_cmd`: skip the `completion` subcommand entirely.
///   The hidden `__complete` runtime is still installed so shell
///   scripts that the user generated via the public `genXCompletion`
///   functions can still call back into the binary.
/// - `hidden_default_cmd`: register `completion` but hide it from help.
pub fn installCompletionCommand(root: *Command, opts: CompletionOptions) !void {
    if (root.findChildByNameOrAlias("completion") != null) return;

    if (!opts.disable_default_cmd) {
        const completion = try Command.init(root.allocator, .{
            .use = "completion",
            .short = "Generate shell completion scripts",
            .long = "Generate shell completion scripts. To load completions:\n  bash:        eval \"$(... completion bash)\"\n  zsh:         eval \"$(... completion zsh)\"\n  fish:        ... completion fish | source\n  powershell:  ... completion powershell | Invoke-Expression",
            .hidden = opts.hidden_default_cmd,
        });
        try root.addCommand(completion);
        try installShellChildren(completion);
    }

    if (root.findChildByNameOrAlias("__complete") == null) {
        const cc = try Command.init(root.allocator, .{
            .use = "__complete",
            .hidden = true,
            .short = "Compute completion candidates (called by shell scripts)",
            .run_e = completeCmdRun,
        });
        try root.addCommand(cc);
    }
}

fn completeCmdRun(cmd: *Command, run_args: []const []const u8) anyerror!void {
    const root = if (cmd.parent) |p| p else cmd;
    const w = root.outWriter() orelse return;
    try completeCommand(cmd.allocator, root, run_args, w);
}

fn installShellChildren(completion: *Command) !void {
    inline for (.{ "bash", "zsh", "fish", "powershell" }) |shell_name| {
        const sub = try Command.init(completion.allocator, .{
            .use = shell_name,
            .short = "Generate " ++ shell_name ++ " completion script",
            .run_e = ShellRun.shellRunFor(shell_name),
        });
        try completion.addCommand(sub);
    }
}

/// Internal: per-shell Run handler that calls the right generator
/// against the writer. We get to the root via cmd.parent.parent.
const ShellRun = struct {
    fn shellRunFor(comptime shell: []const u8) zobra.HookFnE {
        return struct {
            fn run(cmd: *Command, _: []const []const u8) anyerror!void {
                const root = if (cmd.parent) |p| (if (p.parent) |gp| gp else p) else cmd;
                const allocator = cmd.allocator;
                const w = root.outWriter() orelse return;
                if (comptime std.mem.eql(u8, shell, "bash")) {
                    try @import("bash.zig").genBashCompletion(allocator, root, w);
                } else if (comptime std.mem.eql(u8, shell, "zsh")) {
                    try @import("zsh.zig").genZshCompletion(allocator, root, w);
                } else if (comptime std.mem.eql(u8, shell, "fish")) {
                    try @import("fish.zig").genFishCompletion(allocator, root, w);
                } else if (comptime std.mem.eql(u8, shell, "powershell")) {
                    try @import("powershell.zig").genPowerShellCompletion(allocator, root, w);
                }
            }
        }.run;
    }
};

const testing = std.testing;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "completeCommand: emits subcommand candidates" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .short = "Greet", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .short = "List", .run_e = noopRun }));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completeCommand(gpa, root, &.{""}, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "greet\tGreet") != null);
    try testing.expect(std.mem.indexOf(u8, out, "list\tList") != null);
    try testing.expect(std.mem.endsWith(u8, out, ":4\n")); // NoFileComp directive
}

test "completeCommand: filters by partial-token prefix" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .run_e = noopRun }));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try completeCommand(gpa, root, &.{"l"}, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "list") != null);
    try testing.expect(std.mem.indexOf(u8, out, "greet") == null);
}

test "installCompletionCommand: registers `completion bash/zsh/fish/powershell`" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try installCompletionCommand(root, .{});

    const completion = root.findChildByNameOrAlias("completion") orelse return error.TestUnexpectedResult;
    try testing.expect(completion.findChildByNameOrAlias("bash") != null);
    try testing.expect(completion.findChildByNameOrAlias("zsh") != null);
    try testing.expect(completion.findChildByNameOrAlias("fish") != null);
    try testing.expect(completion.findChildByNameOrAlias("powershell") != null);
}

test "installCompletionCommand: idempotent" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try installCompletionCommand(root, .{});
    const after_first = root.children.items.len;
    try installCompletionCommand(root, .{});
    try testing.expectEqual(after_first, root.children.items.len);
    // Both `completion` and `__complete` are present.
    try testing.expect(root.findChildByNameOrAlias("completion") != null);
    try testing.expect(root.findChildByNameOrAlias("__complete") != null);
}

test "installCompletionCommand: __complete responds with subcommand candidates" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .short = "Greet", .run_e = noopRun }));
    try installCompletionCommand(root, .{});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    root.setOut(&aw.writer);
    try root.execute(&.{ "__complete", "g" }, null);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "greet") != null);
    try testing.expect(std.mem.endsWith(u8, out, ":4\n"));
}
