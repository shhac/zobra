//! zobra-completion — shell completion script generators + the
//! `__complete` runtime callback. Mirrors cobra's bundled completion
//! support (bash_completionsV2.go, zsh_completions.go, fish_completions.go,
//! powershell_completions.go, completions.go).
//!
//! Source of truth: cobra. Scripts shipped here produce working
//! shell completion that calls back into the binary's `__complete`
//! subcommand to get candidates. The runtime side is in runtime.zig.

const std = @import("std");
const zobra = @import("zobra");

pub const Command = zobra.Command;

const directive_mod = @import("directive.zig");
const options_mod = @import("options.zig");
const runtime_mod = @import("runtime.zig");
const bash = @import("bash.zig");
const zsh = @import("zsh.zig");
const fish = @import("fish.zig");
const powershell = @import("powershell.zig");

// Shell completion directives — bitfield per cobra's ShellCompDirective.
pub const ShellCompDirective = directive_mod.ShellCompDirective;

// Per-command runtime config. Mirrors cobra.CompletionOptions.
pub const CompletionOptions = options_mod.CompletionOptions;

// Per-command callback returning completion candidates for positional
// arguments. Mirrors cobra.ValidArgsFunction.
pub const ValidArgsFunction = runtime_mod.ValidArgsFunction;

// Per-flag callback. Mirrors cobra.RegisterFlagCompletionFunc.
pub const FlagCompletionFunction = runtime_mod.FlagCompletionFunction;

// Generators.
pub const genBashCompletion = bash.genBashCompletion;
pub const genBashCompletionV2 = bash.genBashCompletion; // alias for cobra parity
pub const genZshCompletion = zsh.genZshCompletion;
pub const genFishCompletion = fish.genFishCompletion;
pub const genPowerShellCompletion = powershell.genPowerShellCompletion;
pub const genPowerShellCompletionWithDesc = powershell.genPowerShellCompletionWithDesc;

// Runtime entry point: compute completions for argv, write them to
// the writer in the cobra completion-protocol shape (one
// `value\tdescription` line per candidate, then `:directive` trailer).
pub const completeCommand = runtime_mod.completeCommand;

// Auto-register the `completion [shell]` subcommand on a root
// Command. Mirrors cobra's InitDefaultCompletionCmd. Idempotent.
pub const installCompletionCommand = runtime_mod.installCompletionCommand;

test {
    _ = directive_mod;
    _ = options_mod;
    _ = runtime_mod;
    _ = bash;
    _ = zsh;
    _ = fish;
    _ = powershell;
}
