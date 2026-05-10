//! Per-FlagSet "Flag usages" rendering. Mirrors pflag's
//! FlagUsagesWrapped (flag.go:707). Output is byte-aligned columns:
//!
//!     -n, --name string         who to greet (default "world")
//!         --kvs stringToString  string-to-string map
//!     -v, --verbose count       verbose level (repeatable)
//!
//! Hidden flags are excluded. Deprecated flags get a `(DEPRECATED: msg)`
//! suffix. We don't yet wrap long lines (pflag's `FlagUsagesWrapped(cols)`
//! handles that — easy follow-up if a fixture forces it).

const std = @import("std");
const flag_mod = @import("../flag/flag.zig");

pub const FlagSet = flag_mod.FlagSet;
pub const Flag = flag_mod.Flag;
pub const ValueType = flag_mod.ValueType;

/// Render this flag-set as a usage block. Caller frees the returned slice.
/// Returns "" (zero-length, allocated) when every flag is hidden.
pub fn flagUsages(allocator: std.mem.Allocator, set: *const FlagSet) ![]u8 {
    return flagUsagesMerged(allocator, &.{set});
}

/// One rendered flag line, split at the alignment column. `prefix` is
/// `"  -n, --name string"`-shape; `tail` is the description plus any
/// `(default …)` / `(DEPRECATED: …)` suffix. Both slices are owned by
/// the caller.
const RenderedLine = struct {
    prefix: []u8,
    tail: []u8,

    fn deinit(self: RenderedLine, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.tail);
    }
};

/// Render multiple FlagSets as one merged, name-sorted usage block.
/// cobra's default rendering merges `Flags()` + `PersistentFlags()` for
/// the current command's "Flags:" section, and merges every ancestor's
/// persistent flags for the "Global Flags:" section. Sorted by flag name.
pub fn flagUsagesMerged(allocator: std.mem.Allocator, sets: []const *const FlagSet) ![]u8 {
    // Collect non-hidden flags from every set.
    var flags: std.ArrayListUnmanaged(*const Flag) = .empty;
    defer flags.deinit(allocator);
    for (sets) |set| {
        for (set.ordered.items) |flag| {
            if (flag.hidden) continue;
            try flags.append(allocator, flag);
        }
    }

    std.mem.sort(*const Flag, flags.items, {}, lessByName);

    var lines: std.ArrayListUnmanaged(RenderedLine) = .empty;
    defer {
        for (lines.items) |l| l.deinit(allocator);
        lines.deinit(allocator);
    }

    var maxlen: usize = 0;
    for (flags.items) |flag| {
        const line = try renderLine(allocator, flag);
        if (line.prefix.len > maxlen) maxlen = line.prefix.len;
        try lines.append(allocator, line);
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    for (lines.items) |line| {
        try w.writeAll(line.prefix);
        // pflag's Fprintln pattern: prefix + " " + spacing + " " + tail.
        // For the longest line (prefix.len == maxlen) that's exactly
        // 2 spaces; shorter lines get (maxlen - prefix.len) extra spaces
        // so descriptions line up.
        const pad_count = maxlen - line.prefix.len + 2;
        try w.splatByteAll(' ', pad_count);
        try w.writeAll(line.tail);
        try w.writeByte('\n');
    }

    return aw.toOwnedSlice();
}

fn lessByName(_: void, a: *const Flag, b: *const Flag) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Render one flag into its alignment-column-split halves:
///   prefix = "  -n, --name string" (or "      --name string" if no shorthand)
///   tail   = "who to greet (default \"world\") (DEPRECATED: …)"
fn renderLine(allocator: std.mem.Allocator, flag: *const Flag) !RenderedLine {
    var prefix_aw: std.Io.Writer.Allocating = .init(allocator);
    defer prefix_aw.deinit();
    const pw = &prefix_aw.writer;

    if (flag.shorthand != 0 and flag.deprecated.len == 0) {
        try pw.print("  -{c}, --{s}", .{ flag.shorthand, flag.name });
    } else {
        try pw.print("      --{s}", .{flag.name});
    }

    const unquoted = unquoteUsage(flag);
    if (unquoted.varname.len > 0) {
        try pw.print(" {s}", .{unquoted.varname});
    }

    // pflag's NoOptDefVal hint — `--flag[=X]` for non-default sentinels.
    if (flag.no_opt_def_val.len > 0) {
        switch (flag.value_type) {
            .string => try pw.print("[=\"{s}\"]", .{flag.no_opt_def_val}),
            .bool => if (!std.mem.eql(u8, flag.no_opt_def_val, "true")) {
                try pw.print("[={s}]", .{flag.no_opt_def_val});
            },
            .count => if (!std.mem.eql(u8, flag.no_opt_def_val, "+1")) {
                try pw.print("[={s}]", .{flag.no_opt_def_val});
            },
            else => try pw.print("[={s}]", .{flag.no_opt_def_val}),
        }
    }
    const prefix = try prefix_aw.toOwnedSlice();
    errdefer allocator.free(prefix);

    var tail_aw: std.Io.Writer.Allocating = .init(allocator);
    defer tail_aw.deinit();
    const tw = &tail_aw.writer;
    try tw.writeAll(unquoted.usage);
    if (!defaultIsZeroValue(flag)) {
        if (flag.value_type == .string) {
            try tw.print(" (default \"{s}\")", .{flag.default_value_string});
        } else {
            try tw.print(" (default {s})", .{flag.default_value_string});
        }
    }
    if (flag.deprecated.len > 0) {
        try tw.print(" (DEPRECATED: {s})", .{flag.deprecated});
    }
    const tail = try tail_aw.toOwnedSlice();

    return .{ .prefix = prefix, .tail = tail };
}

pub const Unquoted = struct {
    varname: []const u8,
    usage: []const u8,
};

/// Mirror of pflag.UnquoteUsage. Looks for a back-quoted segment in the
/// usage string and pulls it out as the varname; otherwise falls back to
/// a type-name display string. The back-quoted form is recognised but the
/// stripped-usage variant isn't yet stitched (no fixture uses it).
pub fn unquoteUsage(flag: *const Flag) Unquoted {
    const usage = flag.usage;
    var i: usize = 0;
    while (i < usage.len) : (i += 1) {
        if (usage[i] == '`') {
            var j: usize = i + 1;
            while (j < usage.len) : (j += 1) {
                if (usage[j] == '`') {
                    return .{ .varname = usage[i + 1 .. j], .usage = usage };
                }
            }
            break;
        }
    }
    return .{ .varname = typeDisplayName(flag.value_type), .usage = usage };
}

/// Maps a ValueType to the column-rendered type name pflag prints.
pub fn typeDisplayName(t: ValueType) []const u8 {
    return switch (t) {
        .string => "string",
        .bool => "", // boolean shows nothing
        .int => "int",
        .int8 => "int8",
        .int16 => "int16",
        .int32 => "int32",
        .int64 => "int", // pflag normalises int64 → "int"
        .uint => "uint",
        .uint8 => "uint8",
        .uint16 => "uint16",
        .uint32 => "uint32",
        .uint64 => "uint", // pflag normalises uint64 → "uint"
        .float32 => "float32",
        .float64 => "float", // pflag normalises float64 → "float"
        .count => "count",
        .duration => "duration",
        .string_slice => "strings", // pflag's stringSlice → "strings"
        .string_array => "stringArray",
        .int_slice => "ints",
    };
}

/// Mirror of pflag.defaultIsZeroValue.
pub fn defaultIsZeroValue(flag: *const Flag) bool {
    return switch (flag.value_type) {
        .bool => std.mem.eql(u8, flag.default_value_string, "false") or flag.default_value_string.len == 0,
        .duration => std.mem.eql(u8, flag.default_value_string, "0") or std.mem.eql(u8, flag.default_value_string, "0s"),
        .int, .int8, .int16, .int32, .int64, .uint, .uint8, .uint16, .uint32, .uint64, .count, .float32, .float64 => std.mem.eql(u8, flag.default_value_string, "0"),
        .string => flag.default_value_string.len == 0,
        .string_slice, .string_array, .int_slice => std.mem.eql(u8, flag.default_value_string, "[]"),
    };
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

test "flagUsages: column alignment" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var name: []const u8 = "world";
    var verbose: i32 = 0;
    var dry: bool = false;
    try fs.stringVarP(&name, "name", 'n', "world", "who to greet");
    try fs.countVarP(&verbose, "verbose", 'v', "verbose level");
    try fs.boolVarP(&dry, "dry-run", 'd', false, "print but do not act");

    const out = try flagUsages(gpa, &fs);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "  -n, --name string") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(default \"world\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  -v, --verbose count") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  -d, --dry-run") != null);
}

test "flagUsages: hidden flags excluded" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var s: []const u8 = "";
    try fs.stringVarP(&s, "secret", 0, "", "");
    try fs.markHidden("secret");

    const out = try flagUsages(gpa, &fs);
    defer gpa.free(out);
    try testing.expectEqualStrings("", out);
}

test "flagUsages: deprecated flags labelled" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var s: []const u8 = "";
    try fs.stringVarP(&s, "old", 'o', "", "the old way");
    try fs.markDeprecated("old", "use --new");

    fs.lookup("old").?.hidden = false;

    const out = try flagUsages(gpa, &fs);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "(DEPRECATED: use --new)") != null);
    // Deprecated flags don't print their shorthand per pflag.
    try testing.expect(std.mem.indexOf(u8, out, "-o, --old") == null);
    try testing.expect(std.mem.indexOf(u8, out, "      --old") != null);
}

test "typeDisplayName: pflag-style normalisation" {
    try testing.expectEqualStrings("int", typeDisplayName(.int64));
    try testing.expectEqualStrings("uint", typeDisplayName(.uint64));
    try testing.expectEqualStrings("float", typeDisplayName(.float64));
    try testing.expectEqualStrings("", typeDisplayName(.bool));
}

test "defaultIsZeroValue: type-aware" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var s: []const u8 = "";
    try fs.stringVarP(&s, "empty", 0, "", "");
    try testing.expect(defaultIsZeroValue(fs.lookup("empty").?));

    var b: bool = false;
    try fs.boolVarP(&b, "off", 0, false, "");
    try testing.expect(defaultIsZeroValue(fs.lookup("off").?));

    var n: i64 = 5;
    try fs.intVarP(&n, "five", 0, 5, "");
    try testing.expect(!defaultIsZeroValue(fs.lookup("five").?));
}
