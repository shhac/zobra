//! zobra — a Zig port of the cobra CLI framework.
//!
//! See README.md and design-docs/ for the full picture. This file is the
//! public API surface; for now it is intentionally thin (Phase 0 scaffold).
//! Phase 1 lands the parser; subsequent phases grow this module.

const std = @import("std");

pub const version = "0.0.0";

/// Writes a placeholder banner to the given writer. Exists so the example
/// executable has something to call before the real surface lands.
pub fn hello(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("zobra v{s} — scaffold (Phase 0)\n", .{version});
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "hello writes a banner" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try hello(&w);
    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "zobra") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, version) != null);
}
