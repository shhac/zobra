//! Error sets for zobra. Tags are flat; rich context lives on a Diagnostic
//! the caller passes in. See design-docs/07-error-model.md.

const std = @import("std");

pub const ParseError = error{
    /// `--unknown` or `-x` (where `x` isn't a registered shorthand).
    UnknownFlag,
    /// A subcommand path that doesn't resolve.
    UnknownCommand,
    /// `--flag` (or `-f`) requires a value but the next token wasn't one.
    MissingValue,
    /// Reserved for short-group structural errors that aren't UnknownFlag.
    InvalidShortGroup,
    /// `---name`, `--=value`, `--` followed by another `-`, etc.
    /// Mirrors pflag's `bad flag syntax: %s`.
    BadFlagSyntax,
};

pub const FlagError = error{
    TypeCoercionFailed,
    RequiredFlagMissing,
    FlagGroupViolation,
};

pub const CommandError = error{
    ArgsValidationFailed,
    NoRunDefined,
};

/// The combined parser-layer error set. The parser itself can fail with a
/// `ParseError` (invalid syntax / unknown flag / missing value) or with an
/// allocator-induced `OutOfMemory`. Higher layers either bubble or
/// normalise into a Diagnostic.
pub const ParserError = ParseError || std.mem.Allocator.Error;
