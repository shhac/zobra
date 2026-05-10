const std = @import("std");
const Io = std.Io;
const zobra = @import("zobra");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try zobra.hello(stdout);
    try stdout.flush();
}
