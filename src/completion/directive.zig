//! ShellCompDirective bitfield. Mirrors cobra's ShellCompDirective
//! constants byte-for-byte (the integer values are part of the
//! shell-script wire format — must match cobra exactly).

const std = @import("std");

/// Bitfield combining shell-completion directives. Cobra's encoding;
/// the integer values are baked into the generated shell scripts,
/// so they must match cobra's exactly.
pub const ShellCompDirective = struct {
    pub const Default: u32 = 0;
    pub const Error: u32 = 1 << 0;
    pub const NoSpace: u32 = 1 << 1;
    pub const NoFileComp: u32 = 1 << 2;
    pub const FilterFileExt: u32 = 1 << 3;
    pub const FilterDirs: u32 = 1 << 4;
    pub const KeepOrder: u32 = 1 << 5;

    /// Format the directive for emission as the trailing `:N` of a
    /// __complete response.
    pub fn format(directive: u32, w: *std.Io.Writer) !void {
        try w.print(":{d}", .{directive});
    }
};

const testing = std.testing;

test "ShellCompDirective: bitfield values match cobra" {
    try testing.expectEqual(@as(u32, 0), ShellCompDirective.Default);
    try testing.expectEqual(@as(u32, 1), ShellCompDirective.Error);
    try testing.expectEqual(@as(u32, 2), ShellCompDirective.NoSpace);
    try testing.expectEqual(@as(u32, 4), ShellCompDirective.NoFileComp);
    try testing.expectEqual(@as(u32, 8), ShellCompDirective.FilterFileExt);
    try testing.expectEqual(@as(u32, 16), ShellCompDirective.FilterDirs);
    try testing.expectEqual(@as(u32, 32), ShellCompDirective.KeepOrder);
}

test "ShellCompDirective: format trailer" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try ShellCompDirective.format(ShellCompDirective.NoSpace | ShellCompDirective.NoFileComp, &w);
    try testing.expectEqualStrings(":6", w.buffered());
}
