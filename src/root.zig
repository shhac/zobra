//! zobra — a Zig port of the cobra CLI framework.
//!
//! See README.md and design-docs/ for the full picture.
//! Phase 1 ships the parser + supporting types (Diagnostic, error sets,
//! Token alphabet). Subsequent phases grow the FlagSet, Command runtime,
//! help renderer, and surrounding infrastructure.

const std = @import("std");

pub const version = "0.0.0";

const errors_mod = @import("core/errors.zig");
pub const ParseError = errors_mod.ParseError;
pub const FlagError = errors_mod.FlagError;
pub const CommandError = errors_mod.CommandError;
pub const ParserError = errors_mod.ParserError;

pub const Diagnostic = @import("core/diagnostic.zig").Diagnostic;

pub const parser = struct {
    const parser_mod = @import("core/parser/parser.zig");
    pub const parse = parser_mod.parse;
    pub const FlagSchema = parser_mod.FlagSchema;
    pub const Token = @import("core/parser/token.zig").Token;
};

pub const flag = struct {
    const flag_mod = @import("core/flag/flag.zig");
    pub const FlagSet = flag_mod.FlagSet;
    pub const ValueType = flag_mod.ValueType;
    pub const Flag = flag_mod.Flag;
    pub const duration = @import("core/flag/duration.zig");
    pub const coerce = @import("core/flag/coerce.zig");
};

pub const FlagSet = flag.FlagSet;

const command_mod = @import("core/command/command.zig");
pub const Command = command_mod.Command;
pub const args = @import("core/command/args.zig");
pub const ArgsValidator = args.ArgsValidator;

/// Writes a placeholder banner to the given writer. Goes away once the
/// example exe has something more meaningful to show (Phase 3).
pub fn hello(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("zobra v{s} — scaffold (Phase 0–1)\n", .{version});
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("core/diagnostic.zig");
    _ = @import("core/errors.zig");
    _ = @import("core/parser/parser.zig");
    _ = @import("core/parser/token.zig");
    _ = @import("core/parser/long.zig");
    _ = @import("core/parser/short.zig");
    _ = @import("core/flag/coerce.zig");
    _ = @import("core/flag/duration.zig");
    _ = @import("core/flag/flag.zig");
    _ = @import("core/command/args.zig");
    _ = @import("core/command/command.zig");
    _ = @import("core/command/hook.zig");
    _ = @import("core/command/suggest.zig");
    _ = @import("core/help/usage.zig");
    _ = @import("core/help/help.zig");
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
