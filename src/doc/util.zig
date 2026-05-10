//! Shared helpers across the doc generators. Mirrors cobra/doc/util.go.

const std = @import("std");
const zobra = @import("zobra");

pub const Command = zobra.Command;

/// True iff the command has a parent or has any non-hidden child —
/// i.e., there's something to put in a "See also" section.
pub fn hasSeeAlso(cmd: *const Command) bool {
    if (cmd.parent != null) return true;
    for (cmd.children.items) |c| {
        if (c.hidden) continue;
        if (isAdditionalHelpTopicCommand(c)) continue;
        return true;
    }
    return false;
}

/// cobra's IsAdditionalHelpTopicCommand: a command with no Run AND no
/// runnable children. Used to filter out pure help-topic placeholders.
pub fn isAdditionalHelpTopicCommand(cmd: *const Command) bool {
    if (cmd.run_e != null or cmd.run != null) return false;
    for (cmd.children.items) |c| {
        if (c.run_e != null or c.run != null) return false;
    }
    return true;
}

/// cobra's IsAvailableCommand: not hidden, not deprecated, has a Run
/// or has runnable children.
pub fn isAvailableCommand(cmd: *const Command) bool {
    if (cmd.hidden) return false;
    if (cmd.deprecated.len > 0) return false;
    if (cmd.run_e != null or cmd.run != null) return true;
    for (cmd.children.items) |c| {
        if (isAvailableCommand(c)) return true;
    }
    return false;
}

/// Sort children by name for deterministic doc output.
pub fn sortedChildren(allocator: std.mem.Allocator, cmd: *const Command) ![]const *Command {
    const out = try allocator.dupe(*Command, cmd.children.items);
    std.mem.sort(*Command, out, {}, lessByName);
    return out;
}

fn lessByName(_: void, a: *Command, b: *Command) bool {
    return std.mem.lessThan(u8, a.commandName(), b.commandName());
}

/// Replace every space in `s` with `_` — used for filename / link
/// derivation from command paths. Caller frees.
pub fn underscoreSpaces(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, s);
    for (out) |*c| if (c.* == ' ') {
        c.* = '_';
    };
    return out;
}

/// pflag's UseLine: `cmd.use` plus " [flags]" if the command has any
/// non-disabled flags AND the use string doesn't already end in
/// `[flags]` (cobra's logic). Caller frees.
pub fn useLine(allocator: std.mem.Allocator, cmd: *const Command) ![]u8 {
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);
    // Append the args portion of `use` (everything after the command
    // name itself).
    const name = cmd.commandName();
    const args_part = if (cmd.use.len > name.len) cmd.use[name.len..] else "";
    const has_local_flags = cmd.flags_set.ordered.items.len > 0;
    const flags_suffix = if (has_local_flags) " [flags]" else "";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ path, args_part, flags_suffix });
}

const testing = std.testing;

test "underscoreSpaces: replaces every space" {
    const out = try underscoreSpaces(testing.allocator, "a b c d");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a_b_c_d", out);
}

test "hasSeeAlso: parent → true" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    const child = try Command.init(gpa, .{ .use = "child", .run_e = noopRun });
    try root.addCommand(child);
    try testing.expect(hasSeeAlso(child));
}

test "hasSeeAlso: childless leaf → false" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    try testing.expect(!hasSeeAlso(root));
}

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}
