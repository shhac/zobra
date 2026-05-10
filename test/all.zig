//! Integration test entry point. As phases land, this file pulls in
//! per-feature test modules under `test/parser/`, `test/flag/`, etc.

const std = @import("std");
const zobra = @import("zobra");

test {
    _ = @import("parser/mixed.zig");
}

test "scaffold: zobra module imports cleanly" {
    try std.testing.expect(zobra.version.len > 0);
}

test "scaffold: hello writes through a fixed writer" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zobra.hello(&w);
    const written = w.buffered();
    try std.testing.expect(written.len > 0);
}
