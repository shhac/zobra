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
/// derivation from command paths. Caller frees. Thin wrapper around
/// `replaceSpaces` for the common case.
pub fn underscoreSpaces(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return replaceSpaces(allocator, s, '_');
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

/// Replace every occurrence of `' '` in `s` with `repl`. Caller frees.
/// Generalisation of `underscoreSpaces` — kept separate so the common
/// underscore-replacement call sites stay terse.
pub fn replaceSpaces(allocator: std.mem.Allocator, s: []const u8, repl: u8) ![]u8 {
    const out = try allocator.dupe(u8, s);
    for (out) |*c| if (c.* == ' ') {
        c.* = repl;
    };
    return out;
}

/// Collect every non-hidden flag across the supplied flag sets and
/// return them sorted by name. Caller frees the returned slice.
pub fn collectVisibleSortedFlags(
    allocator: std.mem.Allocator,
    sets: []const *const zobra.flag.FlagSet,
) ![]const *const zobra.flag.Flag {
    var list: std.ArrayListUnmanaged(*const zobra.flag.Flag) = .empty;
    defer list.deinit(allocator);
    for (sets) |fs| {
        for (fs.ordered.items) |f| {
            if (f.hidden) continue;
            try list.append(allocator, f);
        }
    }
    const out = try list.toOwnedSlice(allocator);
    std.mem.sort(*const zobra.flag.Flag, out, {}, struct {
        fn lt(_: void, a: *const zobra.flag.Flag, b: *const zobra.flag.Flag) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out;
}

/// Walk up `cmd.parent` chain, collecting each ancestor's persistent
/// flag set. Returns ancestors in walk-order (deepest first). Caller
/// frees. Used by every doc generator's "Options inherited from
/// parent commands" section.
pub fn collectInheritedPersistentSets(
    allocator: std.mem.Allocator,
    cmd: *const Command,
) ![]const *const zobra.flag.FlagSet {
    var list: std.ArrayListUnmanaged(*const zobra.flag.FlagSet) = .empty;
    defer list.deinit(allocator);
    var p = cmd.parent;
    while (p) |parent| : (p = parent.parent) {
        try list.append(allocator, &parent.persistent_flags_set);
    }
    return try list.toOwnedSlice(allocator);
}

/// Sort `cmd.children` by name and filter to those that should appear
/// in doc output (available + not a help-topic-only command). Caller
/// frees.
pub fn docEligibleChildren(allocator: std.mem.Allocator, cmd: *const Command) ![]const *Command {
    const sorted = try sortedChildren(allocator, cmd);
    defer allocator.free(sorted);
    var list: std.ArrayListUnmanaged(*Command) = .empty;
    defer list.deinit(allocator);
    for (sorted) |c| {
        if (!isAvailableCommand(c)) continue;
        if (isAdditionalHelpTopicCommand(c)) continue;
        try list.append(allocator, c);
    }
    return try list.toOwnedSlice(allocator);
}

/// Open `<dir>/<basename><ext>` for write, hand a buffered `*std.Io.Writer`
/// to `gen_fn`, then flush. Centralises the boilerplate that lived
/// verbatim in each `genXxxTree` function. Caller supplies the
/// per-format extension (including the leading `.`) and the `io`
/// context (Zig 0.16's explicit-IO requirement — pass `init.io` from
/// `pub fn main(init: std.process.Init)`).
pub fn writeToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    basename: []const u8,
    ext: []const u8,
    cmd: *const Command,
    gen_fn: *const fn (std.mem.Allocator, *const Command, *std.Io.Writer) anyerror!void,
) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ basename, ext });
    defer allocator.free(filename);
    const full_path = try std.fs.path.join(allocator, &.{ dir, filename });
    defer allocator.free(full_path);

    var file = try std.Io.Dir.cwd().createFile(io, full_path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);
    try gen_fn(allocator, cmd, &fw.interface);
    try fw.interface.flush();
}

const testing = std.testing;

test "underscoreSpaces: replaces every space" {
    const out = try underscoreSpaces(testing.allocator, "a b c d");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a_b_c_d", out);
}

test "replaceSpaces: replaces with arbitrary char" {
    const out = try replaceSpaces(testing.allocator, "a b c", '-');
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a-b-c", out);
}

test "useLine: bare command → just path" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    const out = try useLine(gpa, root);
    defer gpa.free(out);
    try testing.expectEqualStrings("tool", out);
}

test "useLine: with args part" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool [target]", .run_e = noopRun });
    defer root.deinit();
    const out = try useLine(gpa, root);
    defer gpa.free(out);
    try testing.expectEqualStrings("tool [target]", out);
}

test "useLine: with local flags appended" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var v: bool = false;
    try root.flags().boolVarP(&v, "verbose", 'v', false, "v");
    const out = try useLine(gpa, root);
    defer gpa.free(out);
    try testing.expectEqualStrings("tool [flags]", out);
}

test "useLine: with both args and flags" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool [target]", .run_e = noopRun });
    defer root.deinit();
    var v: bool = false;
    try root.flags().boolVarP(&v, "verbose", 'v', false, "v");
    const out = try useLine(gpa, root);
    defer gpa.free(out);
    try testing.expectEqualStrings("tool [target] [flags]", out);
}

test "collectVisibleSortedFlags: sorts and filters hidden" {
    const gpa = testing.allocator;
    var fs = zobra.flag.FlagSet.init(gpa);
    defer fs.deinit();
    var a: bool = false;
    var b: bool = false;
    var c: bool = false;
    try fs.boolVarP(&b, "bravo", 0, false, "b");
    try fs.boolVarP(&a, "alpha", 0, false, "a");
    try fs.boolVarP(&c, "charlie", 0, false, "c");
    fs.lookup("charlie").?.hidden = true;
    const out = try collectVisibleSortedFlags(gpa, &.{&fs});
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alpha", out[0].name);
    try testing.expectEqualStrings("bravo", out[1].name);
}

test "collectInheritedPersistentSets: walks parent chain in deepest-first order" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    const mid = try Command.init(gpa, .{ .use = "mid" });
    try root.addCommand(mid);
    const leaf = try Command.init(gpa, .{ .use = "leaf", .run_e = noopRun });
    try mid.addCommand(leaf);

    const out = try collectInheritedPersistentSets(gpa, leaf);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expect(out[0] == &mid.persistent_flags_set);
    try testing.expect(out[1] == &root.persistent_flags_set);
}

test "docEligibleChildren: sorts and filters hidden + help-topic-only" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "bravo", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "alpha", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "hidden_one", .hidden = true, .run_e = noopRun }));
    // help-topic-only: no run + no runnable children
    try root.addCommand(try Command.init(gpa, .{ .use = "help_topic" }));

    const out = try docEligibleChildren(gpa, root);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("alpha", out[0].commandName());
    try testing.expectEqualStrings("bravo", out[1].commandName());
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
