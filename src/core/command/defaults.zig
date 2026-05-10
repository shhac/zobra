//! Lazy auto-init for the cobra-default `--help` flag, `--version`
//! flag, and `help [command]` subcommand. These are registered on
//! first `executeWith` call (not at `Command.init` time) so a fresh
//! Command tree has no allocation pressure for them until use.
//!
//! Source of truth: cobra's command.go — `InitDefaultHelpFlag`,
//! `AddDefaultHelpCmd`, `InitDefaultVersionFlag`. Same lazy pattern,
//! same lifetime contracts (owned strings stashed on the Command).

const std = @import("std");
const command_mod = @import("command.zig");

const Command = command_mod.Command;

/// Lazy `--help` flag registration on first `execute`. Mirrors cobra's
/// InitDefaultHelpFlag. Sets `help_flag_initialised` only after every
/// step succeeds, so a mid-OOM call leaves the command re-tryable.
pub fn initHelpFlag(self: *Command) !void {
    if (self.help_flag_initialised) return;
    if (self.flags_set.lookup("help") != null) {
        self.help_flag_initialised = true;
        return;
    }

    var help_msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&help_msg_buf, "help for {s}", .{self.commandName()});

    const owned_msg = try self.allocator.dupe(u8, msg);
    errdefer self.allocator.free(owned_msg);

    // Append to the owned-strings list FIRST so the list takes the
    // free responsibility. If boolVarP then fails, the errdefer-pop
    // detaches the entry and the outer errdefer frees `owned_msg`.
    try self.help_owned_strings.append(self.allocator, owned_msg);
    errdefer _ = self.help_owned_strings.pop();

    const shorthand: u8 = if (self.flags_set.shorthandLookup('h') == null) 'h' else 0;
    try self.flags_set.boolVarP(&self.help_flag_value, "help", shorthand, false, owned_msg);

    self.help_flag_initialised = true;
}

/// Lazy `help [command]` subcommand registration on root. Mirrors
/// cobra's AddDefaultHelpCmd: skips installation at a leaf (no
/// children means no help-path makes sense) or when the user already
/// registered a child named `help`.
pub fn initHelpCommand(self: *Command) !void {
    if (self.help_subcommand_initialised) return;
    self.help_subcommand_initialised = true;
    if (self.children.items.len == 0) return;
    if (self.findChildByNameOrAlias("help") != null) return;

    const help_cmd = try Command.init(self.allocator, .{
        .use = "help [command]",
        .short = "Help about any command",
        .long = "Help provides help for any command in the application.",
        .run_e = helpCommandRun,
    });
    try self.addCommand(help_cmd);
}

/// Run handler for the auto-injected `help` subcommand. `cmd` here is
/// the help-command itself; its parent is the root we want to walk.
fn helpCommandRun(cmd: *Command, args: []const []const u8) anyerror!void {
    const root = cmd.parent orelse return;
    const allocator = cmd.allocator;
    const w = root.outWriter() orelse return;

    if (args.len == 0) {
        return root.printHelp(allocator, w);
    }
    const found = try root.findCommand(allocator, args, null);
    defer allocator.free(found.remaining);
    if (found.cmd == root and args.len > 0) {
        try w.print("Unknown help topic [`{s}`]\n", .{args[0]});
        try root.printHelp(allocator, w);
        return;
    }
    try found.cmd.printHelp(allocator, w);
}

/// Lazy `--version` flag registration (only when `Command.version` is
/// non-empty). Cobra binds long-only by default; zobra matches.
pub fn initVersionFlag(self: *Command) !void {
    if (self.version_flag_initialised) return;
    if (self.version.len == 0) {
        self.version_flag_initialised = true;
        return;
    }
    if (self.flags_set.lookup("version") != null) {
        self.version_flag_initialised = true;
        return;
    }

    var buf: [256]u8 = undefined;
    const usage = try std.fmt.bufPrint(&buf, "version for {s}", .{self.commandName()});
    const owned_usage = try self.allocator.dupe(u8, usage);
    errdefer self.allocator.free(owned_usage);

    try self.help_owned_strings.append(self.allocator, owned_usage);
    errdefer _ = self.help_owned_strings.pop();

    try self.flags_set.boolVarP(&self.version_flag_value, "version", 0, false, owned_usage);

    self.version_flag_initialised = true;
}
