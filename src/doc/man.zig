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
    const dashed_path = try util.replaceSpaces(allocator, path, '-');
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

    const inherited = try util.collectInheritedPersistentSets(allocator, cmd);
    defer allocator.free(inherited);
    try writeManFlagsSection(allocator, w, "OPTIONS INHERITED FROM PARENT COMMANDS", inherited);

    if (util.hasSeeAlso(cmd)) {
        try w.writeAll(".SH SEE ALSO\n");
        if (cmd.parent) |parent| {
            const pname = try parent.commandPathString(allocator);
            defer allocator.free(pname);
            try writeManLink(allocator, w, pname, header.section);
        }
        const children = try util.docEligibleChildren(allocator, cmd);
        defer allocator.free(children);
        for (children) |child| {
            const cname = try std.fmt.allocPrint(allocator, "{s} {s}", .{ path, child.commandName() });
            defer allocator.free(cname);
            try writeManLink(allocator, w, cname, header.section);
        }
    }
}

fn writeManLink(allocator: std.mem.Allocator, w: *std.Io.Writer, display_path: []const u8, section: []const u8) !void {
    const dashed = try util.replaceSpaces(allocator, display_path, '-');
    defer allocator.free(dashed);
    try w.print("\\fB{s}({s})\\fP\n", .{ dashed, section });
}

fn writeManFlagsSection(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    section_title: []const u8,
    sets: []const *const zobra.FlagSet,
) !void {
    const flags = try util.collectVisibleSortedFlags(allocator, sets);
    defer allocator.free(flags);
    if (flags.len == 0) return;

    try w.print(".SH {s}\n", .{section_title});
    for (flags) |f| {
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

pub fn genManTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: *const Command,
    header: ManHeader,
    dir: []const u8,
) !void {
    for (cmd.children.items) |c| {
        if (!util.isAvailableCommand(c)) continue;
        if (util.isAdditionalHelpTopicCommand(c)) continue;
        try genManTree(allocator, io, c, header, dir);
    }
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);
    const path_dashed = try util.replaceSpaces(allocator, path, '-');
    defer allocator.free(path_dashed);
    // man pages use `.<section>` as their extension (e.g. `.1`). The
    // header has to be threaded through, so we don't go through
    // `util.writeToFile` here — the bespoke shape lives inline.
    const filename_base = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path_dashed, header.section });
    defer allocator.free(filename_base);
    const full = try std.fs.path.join(allocator, &.{ dir, filename_base });
    defer allocator.free(full);
    var file = try std.Io.Dir.cwd().createFile(io, full, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);
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
