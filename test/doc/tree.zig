//! Filesystem-walker tests for the four `genXxxTree` doc generators.
//! Uses `std.testing.tmpDir` so each test gets an isolated sandbox.
//!
//! Coverage:
//! - One file per non-hidden, non-help-topic command.
//! - Hidden subcommands skipped.
//! - File names use underscore-replaced command path (or dash for man).
//! - File content includes the expected per-format header.

const std = @import("std");
const zobra = @import("zobra");
const doc = @import("zobra-doc");

const Command = zobra.Command;
const Io = std.Io;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

fn makeTwoLevelTree(gpa: std.mem.Allocator) !*Command {
    const root = try Command.init(gpa, .{ .use = "tool", .short = "the tool" });
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .short = "List", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .short = "Greet", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "secret", .short = "Hidden", .hidden = true, .run_e = noopRun }));
    return root;
}

/// Read the first chunk of `<sub_path>` into a caller-owned buffer.
/// Tests only need the prefix to assert the per-format header — no
/// need to slurp the whole file.
fn readPrefix(io: Io, dir: Io.Dir, sub_path: []const u8, buf: []u8) ![]const u8 {
    var f = try dir.openFile(io, sub_path, .{});
    defer f.close(io);
    var reader = f.reader(io, &.{});
    return buf[0..try reader.interface.readSliceShort(buf)];
}

test "genMarkdownTree: writes one file per visible command" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try makeTwoLevelTree(gpa);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // genMarkdownTree resolves files relative to cwd. Build a path
    // relative to cwd via .zig-cache/tmp/<sub_path>.
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir_path);

    try doc.genMarkdownTree(gpa, io, root, dir_path);

    var buf: [256]u8 = undefined;
    inline for (.{ "tool.md", "tool_list.md", "tool_greet.md" }) |name| {
        const body = try readPrefix(io, tmp.dir, name, &buf);
        try std.testing.expect(body.len > 0);
    }

    // Hidden command's file should NOT exist.
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "tool_secret.md", .{}));
}

test "genReSTTree: writes one .rst file per visible command" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try makeTwoLevelTree(gpa);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir_path);

    try doc.genReSTTree(gpa, io, root, dir_path);
    var buf: [256]u8 = undefined;
    const body = try readPrefix(io, tmp.dir, "tool.rst", &buf);
    try std.testing.expect(std.mem.indexOf(u8, body, ".. _tool:") != null);
}

test "genYamlTree: writes one .yaml file per visible command" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try makeTwoLevelTree(gpa);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir_path);

    try doc.genYamlTree(gpa, io, root, dir_path);
    var buf: [256]u8 = undefined;
    const body = try readPrefix(io, tmp.dir, "tool_list.yaml", &buf);
    try std.testing.expect(std.mem.indexOf(u8, body, "name: tool list") != null);
}

test "genManTree: writes one .<section> file per visible command, dash-separated" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = try makeTwoLevelTree(gpa);
    defer root.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir_path);

    try doc.genManTree(gpa, io, root, .{ .section = "1", .source = "TOOL 1.0" }, dir_path);

    var buf: [256]u8 = undefined;
    inline for (.{ "tool.1", "tool-list.1", "tool-greet.1" }) |name| {
        const body = try readPrefix(io, tmp.dir, name, &buf);
        try std.testing.expect(std.mem.startsWith(u8, body, ".TH "));
    }
}

test "genMarkdown: leaf inherits root + middle persistent flags into inherited section" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    const mid = try Command.init(gpa, .{ .use = "middle" });
    try root.addCommand(mid);
    const leaf = try Command.init(gpa, .{ .use = "leaf", .run_e = noopRun });
    try mid.addCommand(leaf);

    var root_cfg: []const u8 = "";
    var mid_region: []const u8 = "";
    var leaf_retries: i64 = 0;
    try root.persistentFlags().stringVarP(&root_cfg, "config", 0, "", "Path to config");
    try mid.persistentFlags().stringVarP(&mid_region, "region", 0, "", "Target region");
    try leaf.flags().intVarP(&leaf_retries, "retries", 0, 3, "Retry count");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try doc.genMarkdown(gpa, leaf, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "### Options inherited from parent commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--config") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--region") != null);
    // --retries belongs in the leaf's own Options section, before the
    // inherited block.
    const inherited_idx = std.mem.indexOf(u8, out, "### Options inherited").?;
    const retries_idx = std.mem.indexOf(u8, out, "--retries").?;
    try std.testing.expect(retries_idx < inherited_idx);
}

test "genMarkdown: hidden inherited persistent flag is excluded" {
    const gpa = std.testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    const leaf = try Command.init(gpa, .{ .use = "leaf", .run_e = noopRun });
    try root.addCommand(leaf);

    var secret: []const u8 = "";
    try root.persistentFlags().stringVarP(&secret, "secret-config", 0, "", "Top-secret");
    root.persistentFlags().lookup("secret-config").?.hidden = true;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try doc.genMarkdown(gpa, leaf, &aw.writer);
    const out = aw.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "--secret-config") == null);
}

test "genYaml: usage with ':' is currently emitted unquoted (regression pin)" {
    // YAML escaping is a known gap (see COMPARISON.md / divergences).
    // This test pins the current behaviour so a future fix can update
    // it deliberately.
    const gpa = std.testing.allocator;
    const cmd = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer cmd.deinit();
    var v: []const u8 = "";
    try cmd.flags().stringVarP(&v, "path", 0, "", "Path: where to write");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try doc.genYaml(gpa, cmd, &aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "usage: Path: where to write") != null);
}
