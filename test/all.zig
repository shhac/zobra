//! Integration test entry point. As phases land, this file pulls in
//! per-feature test modules under `test/parser/`, `test/flag/`, etc.

const std = @import("std");
const zobra = @import("zobra");

test {
    _ = @import("parser/mixed.zig");
    _ = @import("command/command.zig");
    _ = @import("command/multi_level.zig");
    _ = @import("flag/flagset.zig");
    _ = @import("flag/slice_types.zig");
    _ = @import("flag/map_types.zig");
    _ = @import("flag/network_bytes.zig");
    _ = @import("flag/custom_and_changed.zig");
    _ = @import("coverage/oom.zig");
    _ = @import("coverage/wording.zig");
    _ = @import("coverage/duration_boundary.zig");
    _ = @import("coverage/medium.zig");
    _ = @import("completion/scripts.zig");
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
