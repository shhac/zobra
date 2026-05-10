//! Levenshtein-based "Did you mean?" suggestions.
//!
//! Mirrors cobra's `ld` (cobra.go:192) and `SuggestionsFor` (command.go:863).
//! Default minimum distance is 2 (cobra.SuggestionsMinimumDistance).
//! Suggestions also fire on prefix match and on explicit `suggest_for`
//! aliases declared on each Command.

const std = @import("std");

/// Levenshtein distance, optionally case-insensitive.
pub fn distance(allocator: std.mem.Allocator, a: []const u8, b: []const u8, ignore_case: bool) !usize {
    const sa = if (ignore_case) try toLower(allocator, a) else a;
    defer if (ignore_case) allocator.free(sa);
    const sb = if (ignore_case) try toLower(allocator, b) else b;
    defer if (ignore_case) allocator.free(sb);

    // d[i][j] = edit distance between sa[0..i] and sb[0..j].
    const rows = sa.len + 1;
    const cols = sb.len + 1;
    const buf = try allocator.alloc(usize, rows * cols);
    defer allocator.free(buf);

    for (0..rows) |i| buf[i * cols] = i;
    for (0..cols) |j| buf[j] = j;

    var j: usize = 1;
    while (j <= sb.len) : (j += 1) {
        var i: usize = 1;
        while (i <= sa.len) : (i += 1) {
            const idx = i * cols + j;
            if (sa[i - 1] == sb[j - 1]) {
                buf[idx] = buf[(i - 1) * cols + (j - 1)];
            } else {
                const a1 = buf[(i - 1) * cols + j];
                const a2 = buf[i * cols + (j - 1)];
                const a3 = buf[(i - 1) * cols + (j - 1)];
                buf[idx] = @min(@min(a1, a2), a3) + 1;
            }
        }
    }
    return buf[sa.len * cols + sb.len];
}

fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

test "distance: identical is 0" {
    try testing.expectEqual(@as(usize, 0), try distance(testing.allocator, "kitten", "kitten", false));
}

test "distance: kitten → sitting is 3" {
    try testing.expectEqual(@as(usize, 3), try distance(testing.allocator, "kitten", "sitting", false));
}

test "distance: case-insensitive folds before measuring" {
    try testing.expectEqual(@as(usize, 0), try distance(testing.allocator, "Greet", "greet", true));
    try testing.expectEqual(@as(usize, 1), try distance(testing.allocator, "Greet", "great", true));
}

test "distance: empty is the length of the other" {
    try testing.expectEqual(@as(usize, 5), try distance(testing.allocator, "hello", "", false));
    try testing.expectEqual(@as(usize, 5), try distance(testing.allocator, "", "hello", false));
}

test "distance: single insertion / deletion" {
    try testing.expectEqual(@as(usize, 1), try distance(testing.allocator, "abc", "abcd", false));
    try testing.expectEqual(@as(usize, 1), try distance(testing.allocator, "abcd", "abc", false));
}
