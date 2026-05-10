//! CompletionOptions — per-command runtime config for the auto-injected
//! completion subcommand. Mirrors cobra.CompletionOptions.

pub const CompletionOptions = struct {
    /// Skip auto-registration of the `completion [shell]` subcommand.
    /// Use when the CLI handles its own completion setup.
    disable_default_cmd: bool = false,

    /// Skip auto-registration of the `--no-descriptions` flag on each
    /// shell-specific completion subcommand. Cobra's default is to
    /// expose the toggle so users can switch between description-rich
    /// and description-free script variants.
    disable_no_desc_flag: bool = false,

    /// Drop descriptions from emitted completion candidates regardless
    /// of the flag. Useful for shells that don't render descriptions.
    disable_descriptions: bool = false,

    /// Mark the auto-registered `completion` subcommand as hidden.
    /// Cobra exposes it by default so users discover the
    /// `tool completion bash` / `... zsh` / etc. invocations.
    hidden_default_cmd: bool = false,
};
