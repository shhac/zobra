//! Help composer. Procedurally assembles cobra's default help output —
//! Long → Usage → Aliases → Examples → Available Commands → Flags →
//! Global Flags → footer. No template engine; the `setHelpFunc` /
//! `setUsageFunc` overrides cover the cases that would otherwise need
//! one (per design-docs/02 — `text/template` is deferred).

const std = @import("std");
const command_mod = @import("../command/command.zig");
const usage_mod = @import("usage.zig");
const flag_mod = @import("../flag/flag.zig");

pub const Command = command_mod.Command;

/// Render the full help block for `cmd`. Caller frees with the same
/// allocator. Mirrors cobra's HelpTemplate output.
pub fn helpString(allocator: std.mem.Allocator, cmd: *const Command) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    if (cmd.long.len > 0) {
        try w.writeAll(trimTrailingWhitespace(cmd.long));
        try w.writeAll("\n\n");
    } else if (cmd.short.len > 0) {
        try w.writeAll(trimTrailingWhitespace(cmd.short));
        try w.writeAll("\n\n");
    }

    try renderUsageBlock(allocator, w, cmd);

    return aw.toOwnedSlice();
}

/// The "Usage:" portion alone — used on parse-error paths where we want
/// to show usage without the long description.
pub fn usageString(allocator: std.mem.Allocator, cmd: *const Command) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try renderUsageBlock(allocator, &aw.writer, cmd);
    return aw.toOwnedSlice();
}

fn renderUsageBlock(allocator: std.mem.Allocator, w: *std.Io.Writer, cmd: *const Command) !void {
    try w.writeAll("Usage:\n");

    if (cmd.run_e != null or cmd.run != null) {
        try w.writeAll("  ");
        try writeUseLine(w, cmd);
        try w.writeAll("\n");
    }
    if (cmd.children.items.len > 0) {
        try w.writeAll("  ");
        try writeCommandPath(w, cmd);
        try w.writeAll(" [command]\n");
    }

    if (cmd.aliases.len > 0) {
        try w.writeAll("\nAliases:\n  ");
        try w.writeAll(cmd.commandName());
        for (cmd.aliases) |a| {
            try w.writeAll(", ");
            try w.writeAll(a);
        }
        try w.writeAll("\n");
    }

    if (cmd.example.len > 0) {
        try w.writeAll("\nExamples:\n");
        try w.writeAll(cmd.example);
        try w.writeAll("\n");
    }

    if (countAvailableChildren(cmd) > 0) {
        try w.writeAll("\nAvailable Commands:\n");
        try writeCommandList(w, cmd);
    }

    // "Flags:" merges own + own-persistent (cobra's LocalFlags).
    const local_count = countAvailableFlags(&cmd.flags_set) + countAvailableFlags(&cmd.persistent_flags_set);
    if (local_count > 0) {
        try w.writeAll("\nFlags:\n");
        const local_sets: []const *const flag_mod.FlagSet = &.{ &cmd.flags_set, &cmd.persistent_flags_set };
        const flag_block = try usage_mod.flagUsagesMerged(allocator, local_sets);
        defer allocator.free(flag_block);
        try w.writeAll(trimTrailingNewline(flag_block));
        try w.writeAll("\n");
    }

    // "Global Flags:" — every ancestor's persistent flags merged.
    const inherited_block = try inheritedFlagsBlock(allocator, cmd);
    defer allocator.free(inherited_block);
    if (inherited_block.len > 0) {
        try w.writeAll("\nGlobal Flags:\n");
        try w.writeAll(trimTrailingNewline(inherited_block));
        try w.writeAll("\n");
    }

    if (cmd.children.items.len > 0) {
        try w.writeAll("\nUse \"");
        try writeCommandPath(w, cmd);
        try w.writeAll(" [command] --help\" for more information about a command.\n");
    }
}

fn inheritedFlagsBlock(allocator: std.mem.Allocator, cmd: *const Command) ![]u8 {
    var sets: std.ArrayListUnmanaged(*const flag_mod.FlagSet) = .empty;
    defer sets.deinit(allocator);
    var p: ?*const Command = cmd.parent;
    while (p) |up| : (p = up.parent) {
        try sets.append(allocator, &up.persistent_flags_set);
    }
    if (sets.items.len == 0) {
        return try allocator.dupe(u8, "");
    }
    return usage_mod.flagUsagesMerged(allocator, sets.items);
}

fn writeUseLine(w: *std.Io.Writer, cmd: *const Command) !void {
    try writeCommandPath(w, cmd);
    if (cmd.use.len > cmd.commandName().len) {
        try w.writeAll(cmd.use[cmd.commandName().len..]);
    }
    if (countAvailableFlags(&cmd.flags_set) > 0 or cmd.parent != null) {
        try w.writeAll(" [flags]");
    }
}

fn writeCommandPath(w: *std.Io.Writer, cmd: *const Command) !void {
    var stack: [32]*const Command = undefined;
    var depth: usize = 0;
    var p: ?*const Command = cmd;
    while (p) |c| : (p = c.parent) {
        stack[depth] = c;
        depth += 1;
        if (depth == stack.len) break;
    }
    var i = depth;
    var first = true;
    while (i > 0) {
        i -= 1;
        if (!first) try w.writeByte(' ');
        try w.writeAll(stack[i].commandName());
        first = false;
    }
}

/// Cobra's minNamePadding constant (cobra/command.go:35).
const min_name_padding: usize = 11;

fn writeCommandList(w: *std.Io.Writer, cmd: *const Command) !void {
    var max_name_len: usize = 0;
    for (cmd.children.items) |c| {
        if (c.hidden) continue;
        if (c.commandName().len > max_name_len) max_name_len = c.commandName().len;
    }
    const pad_to = @max(min_name_padding, max_name_len);
    for (cmd.children.items) |c| {
        if (c.hidden) continue;
        try w.writeAll("  ");
        try w.writeAll(c.commandName());
        const padding = pad_to - c.commandName().len + 1;
        try w.splatByteAll(' ', padding);
        try w.writeAll(c.short);
        try w.writeAll("\n");
    }
}

fn countAvailableChildren(cmd: *const Command) usize {
    var n: usize = 0;
    for (cmd.children.items) |c| if (!c.hidden) {
        n += 1;
    };
    return n;
}

fn countAvailableFlags(set: *const flag_mod.FlagSet) usize {
    var n: usize = 0;
    for (set.ordered.items) |flag| if (!flag.hidden) {
        n += 1;
    };
    return n;
}

fn trimTrailingWhitespace(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[0..end];
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "helpString: leaf command with flags" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "greet [target]",
        .short = "Print a greeting",
        .long = "Print a friendly greeting to the named target.",
        .run_e = noopRun,
    });
    defer cmd.deinit();

    var name: []const u8 = "world";
    try cmd.flags().stringVarP(&name, "name", 'n', "world", "who to greet");

    const out = try helpString(gpa, cmd);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Print a friendly greeting") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Usage:\n  greet [target]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Flags:\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  -n, --name string") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(default \"world\")") != null);
}

test "helpString: parent with subcommands" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .short = "a tool" });
    defer root.deinit();

    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .short = "Print a greeting", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .short = "List things", .run_e = noopRun }));

    const out = try helpString(gpa, root);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Available Commands:\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  greet") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  list") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Use \"tool [command] --help\" for more information") != null);
}

test "helpString: child sees parent's persistent flags as Global Flags" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();

    var name: []const u8 = "world";
    try root.persistentFlags().stringVarP(&name, "name", 'n', "world", "who to greet");

    const child = try Command.init(gpa, .{ .use = "greet", .run_e = noopRun });
    try root.addCommand(child);

    const out = try helpString(gpa, child);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Global Flags:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--name string") != null);
}

test "helpString: aliases section" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "list",
        .aliases = &.{ "ls", "l" },
        .run_e = noopRun,
    });
    defer cmd.deinit();

    const out = try helpString(gpa, cmd);
    defer gpa.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Aliases:\n  list, ls, l\n") != null);
}

test "usageString: subset of helpString" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "tool",
        .long = "the tool description",
        .run_e = noopRun,
    });
    defer cmd.deinit();

    const help = try helpString(gpa, cmd);
    defer gpa.free(help);
    const usage = try usageString(gpa, cmd);
    defer gpa.free(usage);

    try testing.expect(std.mem.indexOf(u8, help, "the tool description") != null);
    try testing.expect(std.mem.indexOf(u8, usage, "the tool description") == null);
    try testing.expect(std.mem.indexOf(u8, usage, "Usage:") != null);
}
