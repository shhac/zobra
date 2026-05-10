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

    root.execute(argv, null) catch |err| {
        const stderr = std.process.exit;
        _ = stderr;
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
