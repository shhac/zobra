//! Man-page (roff) doc generator. Mirrors cobra/doc/man_docs.go but
//! emits roff directly rather than going through go-md2man (we don't
//! ship the markdown→roff conversion path; the output is simpler and
//! still readable by `man`).

const std = @import("std");
const zobra = @import("zobra");
const util = @import("util.zig");

pub const Command = zobra.Command;

pub const ManHeader = struct {
    /// Manual title (e.g. "TOOL", "GIT-COMMIT").
    title: []const u8 = "",
    /// Manual section ("1" for user commands, "8" for sysadmin, etc.).
    section: []const u8 = "1",
    /// Date string (e.g. "August 2025"). Empty → "auto-generated" date.
    date: []const u8 = "",
    /// Source / origin (e.g. "MyTool 1.0").
    source: []const u8 = "",
    /// Manual title (e.g. "User Commands").
    manual: []const u8 = "User Commands",
};

pub fn genMan(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    header: ManHeader,
    w: *std.Io.Writer,
) !void {
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);
    const path_upper = try toUpper(allocator, path);
    defer allocator.free(path_upper);
    const dashed_path = try replaceSpaces(allocator, path, '-');
    defer allocator.free(dashed_path);

    const title_str = if (header.title.len > 0) header.title else path_upper;
    try w.print(".TH \"{s}\" \"{s}\" \"{s}\" \"{s}\" \"{s}\"\n", .{
        title_str,
        header.section,
        header.date,
        header.source,
        header.manual,
    });

    try w.writeAll(".SH NAME\n");
    if (cmd.short.len > 0) {
        try w.print("{s} \\- {s}\n", .{ dashed_path, cmd.short });
    } else {
        try w.print("{s}\n", .{dashed_path});
    }

    try w.writeAll(".SH SYNOPSIS\n");
    if (cmd.run_e != null or cmd.run != null) {
        const ul = try util.useLine(allocator, cmd);
        defer allocator.free(ul);
        try w.print("\\fB{s}\\fP\n", .{ul});
    } else {
        try w.print("\\fB{s} [command]\\fP\n", .{path});
    }

    if (cmd.long.len > 0) {
        try w.writeAll(".SH DESCRIPTION\n");
        try w.print("{s}\n", .{cmd.long});
    }

    if (cmd.example.len > 0) {
        try w.writeAll(".SH EXAMPLES\n.PP\n");
        try w.writeAll(".nf\n");
        try w.print("{s}\n", .{cmd.example});
        try w.writeAll(".fi\n");
    }

    try writeManFlagsSection(allocator, w, "OPTIONS", &.{ &cmd.flags_set, &cmd.persistent_flags_set });

    var inherited: std.ArrayListUnmanaged(*const zobra.FlagSet) = .empty;
    defer inherited.deinit(allocator);
    var p: ?*const Command = cmd.parent;
    while (p) |up| : (p = up.parent) {
        try inherited.append(allocator, &up.persistent_flags_set);
    }
    try writeManFlagsSection(allocator, w, "OPTIONS INHERITED FROM PARENT COMMANDS", inherited.items);

    if (util.hasSeeAlso(cmd)) {
        try w.writeAll(".SH SEE ALSO\n");
        if (cmd.parent) |parent| {
            const pname = try parent.commandPathString(allocator);
            defer allocator.free(pname);
            const pdash = try replaceSpaces(allocator, pname, '-');
            defer allocator.free(pdash);
            try w.print("\\fB{s}({s})\\fP\n", .{ pdash, header.section });
        }
        const sorted = try util.sortedChildren(allocator, cmd);
        defer allocator.free(sorted);
        for (sorted) |child| {
            if (!util.isAvailableCommand(child)) continue;
            if (util.isAdditionalHelpTopicCommand(child)) continue;
            const cname = try std.fmt.allocPrint(allocator, "{s} {s}", .{ path, child.commandName() });
            defer allocator.free(cname);
            const cdash = try replaceSpaces(allocator, cname, '-');
            defer allocator.free(cdash);
            try w.print("\\fB{s}({s})\\fP\n", .{ cdash, header.section });
        }
    }
}

fn writeManFlagsSection(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    section_title: []const u8,
    sets: []const *const zobra.FlagSet,
) !void {
    var flags: std.ArrayListUnmanaged(*const zobra.flag.Flag) = .empty;
    defer flags.deinit(allocator);
    for (sets) |set| for (set.ordered.items) |f| {
        if (f.hidden) continue;
        try flags.append(allocator, f);
    };
    if (flags.items.len == 0) return;
    std.mem.sort(*const zobra.flag.Flag, flags.items, {}, struct {
        fn lt(_: void, a: *const zobra.flag.Flag, b: *const zobra.flag.Flag) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    try w.print(".SH {s}\n", .{section_title});
    for (flags.items) |f| {
        try w.writeAll(".PP\n");
        if (f.shorthand != 0 and f.deprecated.len == 0) {
            try w.print("\\fB-{c}\\fP, \\fB--{s}\\fP\n", .{ f.shorthand, f.name });
        } else {
            try w.print("\\fB--{s}\\fP\n", .{f.name});
        }
        if (f.usage.len > 0) try w.print(".RS 4\n{s}\n.RE\n", .{f.usage});
    }
}

fn toUpper(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

fn replaceSpaces(allocator: std.mem.Allocator, s: []const u8, with: u8) ![]u8 {
    const out = try allocator.dupe(u8, s);
    for (out) |*c| if (c.* == ' ') {
        c.* = with;
    };
    return out;
}

pub fn genManTree(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    header: ManHeader,
    dir: []const u8,
) !void {
    for (cmd.children.items) |c| {
        if (!util.isAvailableCommand(c)) continue;
        if (util.isAdditionalHelpTopicCommand(c)) continue;
        try genManTree(allocator, c, header, dir);
    }
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);
    const path_dashed = try replaceSpaces(allocator, path, '-');
    defer allocator.free(path_dashed);
    const basename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path_dashed, header.section });
    defer allocator.free(basename);
    const filename = try std.fs.path.join(allocator, &.{ dir, basename });
    defer allocator.free(filename);

    var file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, std.Io.getStdInDefaultIo(), &buf);
    try genMan(allocator, cmd, header, &fw.interface);
    try fw.interface.flush();
}

const testing = std.testing;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "genMan: leaf renders .TH header + sections" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "greet",
        .short = "Print a greeting",
        .long = "Greet a user.",
        .run_e = noopRun,
    });
    defer cmd.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genMan(gpa, cmd, .{ .source = "TOOL 1.0", .date = "January 2026" }, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, ".TH "));
    try testing.expect(std.mem.indexOf(u8, out, ".SH NAME") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".SH SYNOPSIS") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".SH DESCRIPTION") != null);
    try testing.expect(std.mem.indexOf(u8, out, "greet \\- Print a greeting") != null);
}
