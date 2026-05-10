# 01 — Persistent flags

Persistent flags are flags registered on a command that **inherit** down the tree — every subcommand sees them automatically. They're the cobra-idiomatic way to attach config that should be reachable from anywhere in the command tree (verbosity, config paths, output format, etc.).

## Basic shape

```go
// Cobra
var configPath string

root := &cobra.Command{Use: "tool"}
root.PersistentFlags().StringVarP(&configPath, "config", "c", "/etc/tool.yaml", "path to config")

list := &cobra.Command{
    Use:   "list",
    Short: "list things",
    RunE: func(cmd *cobra.Command, args []string) error {
        fmt.Printf("loading %s\n", configPath)
        return nil
    },
}
root.AddCommand(list)
```

```zig
// zobra
var config_path: []const u8 = "/etc/tool.yaml";

const root = try zobra.Command.init(arena, .{ .use = "tool" });
defer root.deinit();
try root.persistentFlags().stringVarP(&config_path, "config", 'c', "/etc/tool.yaml", "path to config");

const list = try zobra.Command.init(arena, .{
    .use = "list",
    .short = "list things",
    .run_e = listRun,
});
try root.addCommand(list);
```

```zig
fn listRun(cmd: *zobra.Command, _: []const []const u8) anyerror!void {
    const w = cmd.outWriter() orelse return;
    try w.print("loading {s}\n", .{config_path});
}
```

All three invocations work, both in cobra and zobra:

```sh
tool --config=/dev/null list
tool list --config=/dev/null      # persistent flag is parse-able after the subcommand
tool -c /dev/null list            # shorthand
```

## Inheritance is recursive

A persistent flag on `root` is visible at every descendant — `root.list.deep`, `root.create.from.template`, anything. Each ancestor's persistent flag set is walked during parse to resolve a flag name.

```go
// Cobra: --config visible at every level
root.PersistentFlags().StringVarP(&configPath, "config", "c", "", "config")
mid := &cobra.Command{Use: "subsys"}
leaf := &cobra.Command{Use: "act", RunE: leafRun}
mid.AddCommand(leaf)
root.AddCommand(mid)
// `tool subsys act --config=foo` works.
```

```zig
// zobra: same — inheritance traversal is automatic
try root.persistentFlags().stringVarP(&config_path, "config", 'c', "", "config");
const mid = try zobra.Command.init(arena, .{ .use = "subsys" });
const leaf = try zobra.Command.init(arena, .{ .use = "act", .run_e = leafRun });
try mid.addCommand(leaf);
try root.addCommand(mid);
```

## Local vs persistent: a quick decision matrix

| Question | If yes → use |
| --- | --- |
| Is it config the entire app needs? (verbosity, config path, output format, debug) | `persistentFlags()` on root |
| Is it specific to one subcommand's behaviour? | `flags()` on that subcommand |
| Is it shared by a few sibling subcommands but not all? | `persistentFlags()` on their common parent |

Mixing styles is fine — a leaf can have local flags AND inherit ancestor persistents. The help renderer separates them into "Flags:" (local) and "Global Flags:" (inherited) sections automatically.

## Subtleties

- **`*T` instead of `&var`.** Cobra passes `&configPath`; zobra passes `&config_path` too — Zig's `&` is identical syntax. The variable must outlive the parse (typically a `var` at module scope or in an arena that lives through `executeAndPrint`).
- **Shorthand is `u8`, not `string`.** `'c'` (single character), not `"c"`. Pass `0` for no shorthand.
- **Default value is duplicated.** zobra's `stringVarP` takes both `&config_path` AND a `"default"` string — the latter is what shows up in `--help`'s `(default …)` annotation, and it's also what's written into `config_path` before parsing. They must agree, like in cobra/pflag.
- **Help-render order.** zobra walks `cmd.parent` upward for inherited persistents; cobra walks `cmd.parent` upward too. Both render alphabetically by name within each section.
- **Persistent flags survive `disable_flag_parsing`** because they're inherited at lookup time, but `disable_flag_parsing` on a child means the parser never tokenizes argv for that child's invocation. If you need them, use a sub-subcommand instead.
