//! Markdown doc generator. Mirrors cobra/doc/md_docs.go.
//!
//! Each command renders to a markdown file with sections:
//!   ## <command path>
//!   <short>
//!   ### Synopsis
//!   <long>
//!   ```
//!   <use line>
//!   ```
//!   ### Examples
//!   ```
//!   <example>
//!   ```
//!   ### Options
//!   ```
//!   <flag-usages of own flags>
//!   ```
//!   ### Options inherited from parent commands
//!   ```
//!   <flag-usages of inherited persistent flags>
//!   ```
//!   ### SEE ALSO
//!   * [parent](parent.md) - parent.short
//!   * [parent child](parent_child.md) - child.short

const std = @import("std");
const zobra = @import("zobra");
const util = @import("util.zig");

pub const Command = zobra.Command;

const md_extension = ".md";

/// Render `cmd` as a markdown document into `w`. Mirrors cobra's
/// GenMarkdown — equivalent to GenMarkdownCustom with an identity
/// link handler.
pub fn genMarkdown(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    w: *std.Io.Writer,
) !void {
    return genMarkdownCustom(allocator, cmd, w, identityLink);
}

fn identityLink(allocator: std.mem.Allocator, s: []const u8) anyerror![]u8 {
    // Caller frees with the SAME allocator passed in.
    return allocator.dupe(u8, s);
}

/// Render with a custom link transformer. linkHandler receives the
/// computed `<path>.md` link string and may rewrite it (e.g., to a
/// path inside a static-site generator's docs tree). The returned
/// slice is freed by genMarkdownCustom.
pub fn genMarkdownCustom(
    allocator: std.mem.Allocator,
    cmd: *const Command,
    w: *std.Io.Writer,
    link_handler: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
) !void {
    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);

    try w.print("## {s}\n\n", .{path});
    if (cmd.short.len > 0) try w.print("{s}\n\n", .{cmd.short});

    if (cmd.long.len > 0) {
        try w.writeAll("### Synopsis\n\n");
        try w.print("{s}\n\n", .{cmd.long});
    }

    if (cmd.run_e != null or cmd.run != null) {
        const ul = try util.useLine(allocator, cmd);
        defer allocator.free(ul);
        try w.print("```\n{s}\n```\n\n", .{ul});
    }

    if (cmd.example.len > 0) {
        try w.writeAll("### Examples\n\n");
        try w.print("```\n{s}\n```\n\n", .{cmd.example});
    }

    try writeOptionsSection(allocator, cmd, w);

    if (util.hasSeeAlso(cmd)) {
        try w.writeAll("### SEE ALSO\n\n");
        if (cmd.parent) |parent| {
            const pname = try parent.commandPathString(allocator);
            defer allocator.free(pname);
            try writeSeeAlsoLink(allocator, w, pname, parent.short, link_handler);
        }
        const children = try util.docEligibleChildren(allocator, cmd);
        defer allocator.free(children);
        for (children) |child| {
            const cname = try std.fmt.allocPrint(allocator, "{s} {s}", .{ path, child.commandName() });
            defer allocator.free(cname);
            try writeSeeAlsoLink(allocator, w, cname, child.short, link_handler);
        }
        try w.writeByte('\n');
    }
}

fn writeSeeAlsoLink(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    display_path: []const u8,
    short: []const u8,
    link_handler: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
) !void {
    const link_raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ display_path, md_extension });
    defer allocator.free(link_raw);
    const link_underscored = try util.underscoreSpaces(allocator, link_raw);
    defer allocator.free(link_underscored);
    const link = try link_handler(allocator, link_underscored);
    defer allocator.free(link);
    try w.print("* [{s}]({s})\t - {s}\n", .{ display_path, link, short });
}

fn writeOptionsSection(allocator: std.mem.Allocator, cmd: *const Command, w: *std.Io.Writer) !void {
    // The flag-rendering machinery (column-alignment, type-display,
    // back-quote unquoting, default/deprecated suffixes) lives in
    // zobra.usage. We call it directly so doc output and `tool --help`
    // can never drift.
    const own = try zobra.usage.flagUsagesMerged(allocator, &.{ &cmd.flags_set, &cmd.persistent_flags_set });
    defer allocator.free(own);
    if (own.len > 0) {
        try w.writeAll("### Options\n\n```\n");
        try w.writeAll(own);
        try w.writeAll("```\n\n");
    }

    const inherited_sets = try util.collectInheritedPersistentSets(allocator, cmd);
    defer allocator.free(inherited_sets);
    if (inherited_sets.len > 0) {
        const inherited = try zobra.usage.flagUsagesMerged(allocator, inherited_sets);
        defer allocator.free(inherited);
        if (inherited.len > 0) {
            try w.writeAll("### Options inherited from parent commands\n\n```\n");
            try w.writeAll(inherited);
            try w.writeAll("```\n\n");
        }
    }
}

/// Walk the command tree and write one markdown file per non-hidden,
/// non-help-topic command into `dir`. Files are named by replacing
/// spaces in the command path with underscores and appending `.md`.
/// (cobra's GenMarkdownTree). `io` is Zig 0.16's explicit-IO context;
/// pass `init.io` from your `main`.
pub fn genMarkdownTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: *const Command,
    dir: []const u8,
) !void {
    return genMarkdownTreeCustom(allocator, io, cmd, dir, emptyPrepender, identityLink);
}

fn emptyPrepender(allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
    return allocator.dupe(u8, "");
}

pub fn genMarkdownTreeCustom(
    allocator: std.mem.Allocator,
    io: std.Io,
    cmd: *const Command,
    dir: []const u8,
    file_prepender: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
    link_handler: *const fn (std.mem.Allocator, []const u8) anyerror![]u8,
) !void {
    for (cmd.children.items) |c| {
        if (!util.isAvailableCommand(c)) continue;
        if (util.isAdditionalHelpTopicCommand(c)) continue;
        try genMarkdownTreeCustom(allocator, io, c, dir, file_prepender, link_handler);
    }

    const path = try cmd.commandPathString(allocator);
    defer allocator.free(path);
    const path_underscored = try util.underscoreSpaces(allocator, path);
    defer allocator.free(path_underscored);
    const basename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path_underscored, md_extension });
    defer allocator.free(basename);
    const filename = try std.fs.path.join(allocator, &.{ dir, basename });
    defer allocator.free(filename);

    var file = try std.Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(file, io, &buf);
    const w = &fw.interface;

    const prepend = try file_prepender(allocator, filename);
    defer allocator.free(prepend);
    if (prepend.len > 0) try w.writeAll(prepend);

    try genMarkdownCustom(allocator, cmd, w, link_handler);
    try w.flush();
}

const testing = std.testing;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "genMarkdown: leaf command renders the canonical sections" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{
        .use = "greet [target]",
        .short = "Print a greeting",
        .long = "Print a friendly greeting to the named target.",
        .example = "  tool greet alice",
        .run_e = noopRun,
    });
    defer cmd.deinit();
    var name: []const u8 = "world";
    try cmd.flags().stringVarP(&name, "name", 'n', "world", "who to greet");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genMarkdown(gpa, cmd, &aw.writer);
    const out = aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "## greet\n\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Print a greeting") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### Synopsis") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Print a friendly greeting") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### Examples") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tool greet alice") != null);
    try testing.expect(std.mem.indexOf(u8, out, "### Options") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  -n, --name string") != null);
}

test "genMarkdown: parent renders SEE ALSO with sorted children" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .short = "a tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .short = "List", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .short = "Greet", .run_e = noopRun }));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genMarkdown(gpa, root, &aw.writer);
    const out = aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, out, "### SEE ALSO") != null);
    // Sorted alphabetically: greet before list.
    const greet_idx = std.mem.indexOf(u8, out, "* [tool greet]").?;
    const list_idx = std.mem.indexOf(u8, out, "* [tool list]").?;
    try testing.expect(greet_idx < list_idx);
}

test "genMarkdown: child includes parent in SEE ALSO" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .short = "the tool" });
    defer root.deinit();
    const child = try Command.init(gpa, .{ .use = "greet", .short = "Greet", .run_e = noopRun });
    try root.addCommand(child);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genMarkdown(gpa, child, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "* [tool](tool.md)\t - the tool") != null);
}
