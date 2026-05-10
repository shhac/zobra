//! YAML doc generator. Mirrors cobra/doc/yaml_docs.go.
//!
//! The output is a YAML document with one top-level mapping per
//! command. Keys: name, synopsis, description, usage, options
//! (sequence), inherited_options (sequence), example, see_also.
//!
//! cobra uses gopkg.in/yaml.v3; zobra emits the same shape by hand
//! (the writes are simple enough to avoid a YAML library).

const std = @import("std");
const zobra = @import("zobra");
const util = @import("util.zig");

pub const Command = zobra.Command;

pub fn genYaml(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    w: *std.Io.Writer,
) !void {
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);

    try w.print("name: {s}\n", .{path});
    if (cmd.short.len > 0) try w.print("synopsis: {s}\n", .{cmd.short});
    if (cmd.long.len > 0) {
        try w.writeAll("description: |\n");
        try writeIndentedBlock(w, cmd.long, "  ");
    }
    if (cmd.run_e != null or cmd.run != null) {
        const ul = try util.useLine(allocator, cmd);
        defer allocator.free(ul);
        try w.print("usage: {s}\n", .{ul});
    }
    if (cmd.example.len > 0) {
        try w.writeAll("example: |\n");
        try writeIndentedBlock(w, cmd.example, "  ");
    }

    try writeYamlFlagsBlock(allocator, w, "options", &.{ &cmd.flags_set, &cmd.persistent_flags_set }, true);

    const inherited = try util.collectInheritedPersistentSets(allocator, cmd);
    defer allocator.free(inherited);
    try writeYamlFlagsBlock(allocator, w, "inherited_options", inherited, true);

    if (util.hasSeeAlso(cmd)) {
        try w.writeAll("see_also:\n");
        if (cmd.parent) |parent| {
            const pname = try parent.commandPathString(allocator);
            defer allocator.free(pname);
            try w.print("- {s}\n", .{pname});
        }
        const children = try util.docEligibleChildren(allocator, cmd);
        defer allocator.free(children);
        for (children) |child| {
            try w.print("- {s} {s}\n", .{ path, child.commandName() });
        }
    }
}

fn writeIndentedBlock(w: *std.Io.Writer, text: []const u8, indent: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try w.writeAll(indent);
        try w.writeAll(line);
        try w.writeByte('\n');
    }
}

fn writeYamlFlagsBlock(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    key: []const u8,
    sets: []const *const zobra.FlagSet,
    sort_by_name: bool,
) !void {
    _ = sort_by_name; // util.collectVisibleSortedFlags always sorts; cobra's yaml emitter also sorts.
    const flags = try util.collectVisibleSortedFlags(allocator, sets);
    defer allocator.free(flags);
    if (flags.len == 0) return;

    try w.print("{s}:\n", .{key});
    for (flags) |f| {
        try w.print("- name: {s}\n", .{f.name});
        if (f.shorthand != 0 and f.deprecated.len == 0) {
            try w.print("  shorthand: {c}\n", .{f.shorthand});
        }
        if (f.usage.len > 0) try w.print("  usage: {s}\n", .{f.usage});
        if (!f.isZeroDefault()) try w.print("  default_value: {s}\n", .{f.default_value_string});
    }
}

pub fn genYamlTree(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    dir: []const u8,
) !void {
    for (cmd.children.items) |c| {
        if (!util.isAvailableCommand(c)) continue;
        if (util.isAdditionalHelpTopicCommand(c)) continue;
        try genYamlTree(allocator, c, dir);
    }
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);
    const path_u = try util.underscoreSpaces(allocator, path);
    defer allocator.free(path_u);
    try util.writeToFile(allocator, dir, path_u, ".yaml", cmd, genYaml);
}

const testing = std.testing;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "genYaml: leaf renders top-level mapping" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "greet",
        .short = "Print a greeting",
        .run_e = noopRun,
    });
    defer cmd.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genYaml(gpa, cmd, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "name: greet") != null);
    try testing.expect(std.mem.indexOf(u8, out, "synopsis: Print a greeting") != null);
    try testing.expect(std.mem.indexOf(u8, out, "usage: greet") != null);
}
