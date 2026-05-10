//! reStructuredText doc generator. Mirrors cobra/doc/rest_docs.go.
//!
//! Sections: title (overlined+underlined), Synopsis, Examples,
//! Options (literal block), Options inherited from parent commands,
//! SEE ALSO.

const std = @import("std");
const zobra = @import("zobra");
const util = @import("util.zig");

pub const Command = zobra.Command;

const rst_extension = ".rst";

pub fn genReST(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    w: *std.Io.Writer,
) !void {
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);

    // ReST title with overline + underline of equal length.
    const path_underscored = try util.underscoreSpaces(allocator, path);
    defer allocator.free(path_underscored);
    try w.print(".. _{s}:\n\n", .{path_underscored});

    const underline = try makeUnderline(allocator, path.len, '=');
    defer allocator.free(underline);
    try w.print("{s}\n", .{path});
    try w.print("{s}\n\n", .{underline});

    if (cmd.short.len > 0) try w.print("{s}\n\n", .{cmd.short});
    if (cmd.long.len > 0) {
        try w.writeAll("Synopsis\n~~~~~~~~\n\n");
        try w.print("{s}\n\n", .{cmd.long});
    }
    if (cmd.run_e != null or cmd.run != null) {
        const ul = try util.useLine(allocator, cmd);
        defer allocator.free(ul);
        try w.print("::\n\n  {s}\n\n", .{ul});
    }
    if (cmd.example.len > 0) {
        try w.writeAll("Examples\n~~~~~~~~\n\n::\n\n");
        try writeIndentedLines(w, cmd.example, "  ");
        try w.writeByte('\n');
    }

    const own = try renderFlagsAsLiteralBlock(allocator, &.{ &cmd.flags_set, &cmd.persistent_flags_set });
    defer allocator.free(own);
    if (own.len > 0) {
        try w.writeAll("Options\n~~~~~~~\n\n::\n\n");
        try w.writeAll(own);
        try w.writeAll("\n");
    }

    const inherited = try util.collectInheritedPersistentSets(allocator, cmd);
    defer allocator.free(inherited);
    const inh = try renderFlagsAsLiteralBlock(allocator, inherited);
    defer allocator.free(inh);
    if (inh.len > 0) {
        try w.writeAll("Options inherited from parent commands\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n::\n\n");
        try w.writeAll(inh);
        try w.writeAll("\n");
    }

    if (util.hasSeeAlso(cmd)) {
        try w.writeAll("SEE ALSO\n~~~~~~~~\n\n");
        if (cmd.parent) |parent| {
            const pname = try parent.commandPathString(allocator);
            defer allocator.free(pname);
            try writeRestLink(allocator, w, pname, parent.short);
        }
        const children = try util.docEligibleChildren(allocator, cmd);
        defer allocator.free(children);
        for (children) |child| {
            const cname = try std.fmt.allocPrint(allocator, "{s} {s}", .{ path, child.commandName() });
            defer allocator.free(cname);
            try writeRestLink(allocator, w, cname, child.short);
        }
        try w.writeByte('\n');
    }
}

fn writeRestLink(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    display_path: []const u8,
    short: []const u8,
) !void {
    const target = try util.underscoreSpaces(allocator, display_path);
    defer allocator.free(target);
    try w.print("* :ref:`{s} <{s}>` \t - {s}\n", .{ display_path, target, short });
}

fn makeUnderline(allocator: std.mem.Allocator, len: usize, ch: u8) ![]u8 {
    const out = try allocator.alloc(u8, len);
    @memset(out, ch);
    return out;
}

fn writeIndentedLines(w: *std.Io.Writer, text: []const u8, indent: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try w.writeAll(indent);
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

/// Render flag list as a ReST literal block: each line indented by 2
/// spaces (the `::\n\n` literal-block convention).
fn renderFlagsAsLiteralBlock(allocator: std.mem.Allocator, sets: []const *const zobra.FlagSet) ![]u8 {
    const flags = try util.collectVisibleSortedFlags(allocator, sets);
    defer allocator.free(flags);
    if (flags.len == 0) return allocator.dupe(u8, "");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    for (flags) |f| {
        try w.writeAll("  "); // ReST literal block indent
        if (f.shorthand != 0 and f.deprecated.len == 0) {
            try w.print("-{c}, --{s}", .{ f.shorthand, f.name });
        } else {
            try w.print("    --{s}", .{f.name});
        }
        if (f.usage.len > 0) try w.print("    {s}", .{f.usage});
        try w.writeByte('\n');
    }
    return aw.toOwnedSlice();
}

pub fn genReSTTree(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    dir: []const u8,
) !void {
    for (cmd.children.items) |c| {
        if (!util.isAvailableCommand(c)) continue;
        if (util.isAdditionalHelpTopicCommand(c)) continue;
        try genReSTTree(allocator, c, dir);
    }
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);
    const path_u = try util.underscoreSpaces(allocator, path);
    defer allocator.free(path_u);
    try util.writeToFile(allocator, dir, path_u, rst_extension, cmd, genReST);
}

const testing = std.testing;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "genReST: leaf renders title + sections" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "greet",
        .short = "Print a greeting",
        .long = "Long form description.",
        .run_e = noopRun,
    });
    defer cmd.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genReST(gpa, cmd, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, ".. _greet:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Synopsis\n~~~~~~~~") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Long form description") != null);
}
