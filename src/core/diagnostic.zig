//! Diagnostic — structured context attached to a returned error tag.
//!
//! Zig errors are flat tags with no payload. To preserve cobra/pflag's rich
//! error context (flag name, raw value, position, suggestion) we use a
//! diagnostic out-parameter the caller passes in. See
//! design-docs/07-error-model.md for the full pattern and
//! design-docs/04-parser.md for parser-specific usage.

const std = @import("std");

pub const Diagnostic = struct {
    category: ?Category = null,
    code: ?Code = null,

    /// Long-flag name (without leading "--") or single-char shorthand
    /// rendered as a length-1 slice. Borrowed from argv where possible;
    /// owned only when the flag layer constructed it (then owns_flag_name).
    flag_name: ?[]const u8 = null,

    /// Raw argv element that produced the error. Always borrowed from argv.
    raw: ?[]const u8 = null,

    /// For shorthand-group errors: the *remaining* shorthand chars at the
    /// point of error, **without** the leading `-`. Mirrors pflag's
    /// `specifiedShorthands` field exactly. For argv `-abc` failing on `b`,
    /// pflag prints `unknown shorthand flag: "b" in -bc` — the value here is
    /// "bc", and the renderer prepends `-`. (Note that pflag's wording uses
    /// the suffix from the point of error, not the original full group.)
    short_group: ?[]const u8 = null,

    /// Index into argv at which the error was detected, when meaningful.
    position: ?usize = null,

    /// Human-readable rendering. Allocated when set; freed by deinit when
    /// owns_message is true.
    message: ?[]const u8 = null,
    owns_message: bool = false,

    /// "Did you mean --name?" — populated by the suggestion engine.
    /// Allocated when owns_suggestion is true.
    suggestion: ?[]const u8 = null,
    owns_suggestion: bool = false,

    /// For OnlyValidArgs / similar — borrowed from the registered flag.
    valid_values: ?[]const []const u8 = null,

    pub const Category = enum { parse, flag, command };

    pub const Code = enum {
        unknown_flag,
        unknown_command,
        missing_value,
        invalid_short_group,
        bad_flag_syntax,
        type_coercion_failed,
        required_flag_missing,
        flag_group_violation,
        deprecated_flag_used,
        args_validation_failed,
        no_run_defined,
    };

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        if (self.owns_message) if (self.message) |m| allocator.free(m);
        if (self.owns_suggestion) if (self.suggestion) |s| allocator.free(s);
        self.* = .{};
    }
};

/// Conditional helper: assign a tagged category+code on a `?*Diagnostic`,
/// no-op when null. Used by every fallible function in the parser/flag
/// layers — the caller may or may not care about diagnostics.
pub fn fill(diag: ?*Diagnostic, category: Diagnostic.Category, code: Diagnostic.Code) void {
    if (diag) |d| {
        d.category = category;
        d.code = code;
    }
}

test "Diagnostic: zero-init is the default" {
    var d: Diagnostic = .{};
    defer d.deinit(std.testing.allocator);
    try std.testing.expect(d.category == null);
    try std.testing.expect(d.code == null);
    try std.testing.expect(d.message == null);
}

test "Diagnostic: fill sets category and code" {
    var d: Diagnostic = .{};
    fill(&d, .parse, .unknown_flag);
    try std.testing.expectEqual(Diagnostic.Category.parse, d.category.?);
    try std.testing.expectEqual(Diagnostic.Code.unknown_flag, d.code.?);
}

test "Diagnostic: fill is null-safe" {
    fill(null, .parse, .unknown_flag);
}

test "Diagnostic: deinit frees an owned message" {
    const gpa = std.testing.allocator;
    var d: Diagnostic = .{};
    d.message = try gpa.dupe(u8, "error: unknown flag --foo");
    d.owns_message = true;
    d.deinit(gpa);
}
