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

    var inherited: std.ArrayListUnmanaged(*const zobra.FlagSet) = .empty;
    defer inherited.deinit(allocator);
    var p: ?*const Command = cmd.parent;
    while (p) |up| : (p = up.parent) {
        try inherited.append(allocator, &up.persistent_flags_set);
    }
    try writeYamlFlagsBlock(allocator, w, "inherited_options", inherited.items, true);

    if (util.hasSeeAlso(cmd)) {
        try w.writeAll("see_also:\n");
        if (cmd.parent) |parent| {
            const pname = try parent.commandPathString(allocator);
            defer allocator.free(pname);
            try w.print("- {s}\n", .{pname});
        }
        const sorted = try util.sortedChildren(allocator, cmd);
        defer allocator.free(sorted);
        for (sorted) |child| {
            if (!util.isAvailableCommand(child)) continue;
            if (util.isAdditionalHelpTopicCommand(child)) continue;
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
    var flags: std.ArrayListUnmanaged(*const zobra.flag.Flag) = .empty;
    defer flags.deinit(allocator);
    for (sets) |set| for (set.ordered.items) |f| {
        if (f.hidden) continue;
        try flags.append(allocator, f);
    };
    if (flags.items.len == 0) return;
    if (sort_by_name) {
        std.mem.sort(*const zobra.flag.Flag, flags.items, {}, struct {
            fn lt(_: void, a: *const zobra.flag.Flag, b: *const zobra.flag.Flag) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
    }

    try w.print("{s}:\n", .{key});
    for (flags.items) |f| {
        try w.print("- name: {s}\n", .{f.name});
        if (f.shorthand != 0 and f.deprecated.len == 0) {
            try w.print("  shorthand: {c}\n", .{f.shorthand});
        }
        if (f.usage.len > 0) try w.print("  usage: {s}\n", .{f.usage});
        if (!isZeroDefault(f)) try w.print("  default_value: {s}\n", .{f.default_value_string});
    }
}

fn isZeroDefault(flag: *const zobra.flag.Flag) bool {
    return switch (flag.value_type) {
        .bool => std.mem.eql(u8, flag.default_value_string, "false") or flag.default_value_string.len == 0,
        .duration => std.mem.eql(u8, flag.default_value_string, "0") or std.mem.eql(u8, flag.default_value_string, "0s"),
        .int, .int8, .int16, .int32, .int64, .uint, .uint8, .uint16, .uint32, .uint64, .count, .float32, .float64 => std.mem.eql(u8, flag.default_value_string, "0"),
        .string => flag.default_value_string.len == 0,
        .string_slice, .string_array, .int_slice, .int32_slice, .int64_slice, .float32_slice, .float64_slice, .bool_slice, .duration_slice, .string_to_string, .string_to_int, .string_to_int64, .bytes_hex, .bytes_base64 => std.mem.eql(u8, flag.default_value_string, "[]"),
        .ip, .ip_mask, .ip_net => flag.default_value_string.len == 0,
        .custom => flag.default_value_string.len == 0,
    };
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
    const basename = try std.fmt.allocPrint(allocator, "{s}.yaml", .{path_u});
    defer allocator.free(basename);
    const filename = try std.fs.path.join(allocator, &.{ dir, basename });
    defer allocator.free(filename);

    var file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, std.Io.getStdInDefaultIo(), &buf);
    try genYaml(allocator, cmd, &fw.interface);
    try fw.interface.flush();
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
