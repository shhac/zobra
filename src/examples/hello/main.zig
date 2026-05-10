//! Tiny zobra demo: a `hello` CLI with a persistent --name flag and a
//! single `greet` subcommand. Phase-3 dogfooding — exercises the full
//! Command tree, persistent flags, and the hook chain.
//!
//!     hello greet              -> hello, world
//!     hello --name=alice greet -> hello, alice
//!     hello greet bob          -> hello, bob
//!     hello -v greet           -> hello, world (verbose=1)

const std = @import("std");
const Io = std.Io;
const zobra = @import("zobra");

var greet_name: []const u8 = "world";
var verbose: i32 = 0;

fn greet(cmd: *zobra.Command, args: []const []const u8) anyerror!void {
    _ = cmd;
    const target = if (args.len > 0) args[0] else greet_name;
    std.debug.print("hello, {s}\n", .{target});
    if (verbose > 0) std.debug.print("verbose={d}\n", .{verbose});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const root = try zobra.Command.init(arena, .{
        .use = "hello",
        .short = "a tiny zobra demo",
    });
    defer root.deinit();

    try root.persistentFlags().stringVarP(&greet_name, "name", 'n', "world", "who to greet");
    try root.persistentFlags().countVarP(&verbose, "verbose", 'v', "verbose level (repeatable)");

    const greet_cmd = try zobra.Command.init(arena, .{
        .use = "greet [target]",
        .short = "print a greeting",
        .args = zobra.args.maximumN(1),
        .run_e = greet,
    });
    try root.addCommand(greet_cmd);

    const argv_full = try init.minimal.args.toSlice(arena);
    const argv = if (argv_full.len > 0) argv_full[1..] else argv_full;

    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    root.setOut(stdout);
    root.setErr(stderr);

    // executeAndPrint matches cobra's `Execute()`: on failure, prints
    // `Error: <msg>\n` + the resolved command's usage block to err_writer
    // (toggle with .silence_errors / .silence_usage on the Options),
    // then propagates the error so the caller decides the exit code.
    root.executeAndPrint(argv) catch |err| {
        try stdout.flush();
        try stderr.flush();
        if (err == error.HelpRequested or err == error.VersionRequested) std.process.exit(0);
        std.process.exit(1);
    };
    try stdout.flush();
    try stderr.flush();
}
