//! PowerShell completion script generator. PS uses
//! Register-ArgumentCompleter; we register a script-block that calls
//! `__complete` and parses the response.

const std = @import("std");
const zobra = @import("zobra");

pub fn genPowerShellCompletion(
    allocator: std.mem.Allocator,
    root: *const zobra.Command,
    w: *std.Io.Writer,
) !void {
    _ = allocator;
    const name = root.commandName();
    try w.print(template, .{ .name = name });
}

/// Cobra exposes a `WithDesc` variant that emits descriptions in the
/// generated script. zobra's PowerShell template already emits the
/// description field unconditionally — the two functions are identical.
/// Alias provided for cobra-parity callers.
pub const genPowerShellCompletionWithDesc = genPowerShellCompletion;

const template =
    \\# PowerShell completion for {[name]s}
    \\
    \\Register-ArgumentCompleter -CommandName '{[name]s}' -ScriptBlock {{
    \\    param($wordToComplete, $commandAst, $cursorPosition)
    \\    $commandElements = $commandAst.CommandElements
    \\    $args = @()
    \\    foreach ($e in $commandElements[1..($commandElements.Length-1)]) {{
    \\        $args += "$e"
    \\    }}
    \\    $args += "$wordToComplete"
    \\    $output = & $commandElements[0] __complete $args 2>$null
    \\    if (-not $output) {{ return }}
    \\    $lines = $output -split "`n"
    \\    $directive = $lines[-1]
    \\    $candidates = $lines[0..($lines.Length - 2)]
    \\    foreach ($line in $candidates) {{
    \\        if (-not $line) {{ continue }}
    \\        $parts = $line -split "`t", 2
    \\        $value = $parts[0]
    \\        $desc = if ($parts.Length -gt 1) {{ $parts[1] }} else {{ $value }}
    \\        [System.Management.Automation.CompletionResult]::new(
    \\            $value, $value, 'ParameterValue', $desc
    \\        )
    \\    }}
    \\}}
    \\
;

const testing = std.testing;

test "genPowerShellCompletion: registers an argument completer" {
    const gpa = testing.allocator;
    const root = try zobra.Command.init(gpa, .{ .use = "mytool" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genPowerShellCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "Register-ArgumentCompleter") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-CommandName 'mytool'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "__complete") != null);
}
