// Cobra reference binary — the differential-testing oracle.
//
// This program is the behavioural ground truth for vipvot. The vipvot test
// suite captures its stdout/stderr/exit-code into JSON fixtures and asserts
// vipvot reproduces them.
//
// PHASE 0 STATUS: deliberately thin. This binary covers persistent flags
// (string/count/string-slice), a leaf RunE, mutex/required-together/one-
// required flag groups, and a single hook example. The full surface
// described in ../design-docs/05-oracle-testing.md (deep nesting, hidden/
// deprecated/required flags, duration/aliases, custom Args validators,
// command groups) is grown in step with vipvot's roadmap — each phase that
// adds a feature to vipvot also adds the matching exerciser here.
//
// When adding a new cobra behaviour to vipvot, add a corresponding subcommand
// or flag here so the oracle can witness it. See ../design-docs/05-oracle-testing.md.

package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/cobra/doc"
)

func main() {
	root := newRootCmd()
	if err := root.Execute(); err != nil {
		// cobra already prints to stderr; exit non-zero.
		os.Exit(1)
	}
}

func newRootCmd() *cobra.Command {
	var (
		verbose int
		name    string
		tags    []string
	)

	root := &cobra.Command{
		Use:   "oracle",
		Short: "Cobra reference binary used to differential-test vipvot",
		Long:  "A kitchen-sink cobra application. Every behaviour vipvot mirrors is exercised somewhere in this tree.",
	}

	// Suppress cobra's auto-injected `completion` subcommand. It pollutes
	// help output with shell-completion machinery vipvot does not implement
	// (Phase 8+) and would otherwise cause every help fixture to diverge.
	root.CompletionOptions.DisableDefaultCmd = true

	var dryRun bool
	var retries int
	var bigCount int64
	var ratio float64

	root.PersistentFlags().CountVarP(&verbose, "verbose", "v", "verbose level (repeatable)")
	root.PersistentFlags().StringVarP(&name, "name", "n", "world", "name to greet")
	root.PersistentFlags().StringSliceVarP(&tags, "tag", "t", nil, "tags (comma-split or repeated)")

	var labels []string
	root.PersistentFlags().StringArrayVar(&labels, "label", nil, "labels (raw, no comma split)")
	root.PersistentFlags().BoolVarP(&dryRun, "dry-run", "d", false, "print but do not act")
	root.PersistentFlags().IntVarP(&retries, "retries", "r", 0, "retry count")
	root.PersistentFlags().Int64Var(&bigCount, "big-count", 0, "very large counter")
	root.PersistentFlags().Float64Var(&ratio, "ratio", 0, "a ratio")

	var i8 int8
	var i16 int16
	var i32 int32
	var u uint
	var u8 uint8
	var u16 uint16
	var u32 uint32
	var u64 uint64
	var f32 float32
	root.PersistentFlags().Int8Var(&i8, "i8", 0, "int8")
	root.PersistentFlags().Int16Var(&i16, "i16", 0, "int16")
	root.PersistentFlags().Int32Var(&i32, "i32", 0, "int32")
	root.PersistentFlags().UintVar(&u, "u", 0, "uint")
	root.PersistentFlags().Uint8Var(&u8, "u8", 0, "uint8")
	root.PersistentFlags().Uint16Var(&u16, "u16", 0, "uint16")
	root.PersistentFlags().Uint32Var(&u32, "u32", 0, "uint32")
	root.PersistentFlags().Uint64Var(&u64, "u64", 0, "uint64")
	root.PersistentFlags().Float32Var(&f32, "f32", 0, "float32")

	var ints []int
	var i64s []int64
	var f64s []float64
	var bools []bool
	var durs []time.Duration
	root.PersistentFlags().IntSliceVar(&ints, "ints", nil, "int slice")
	root.PersistentFlags().Int64SliceVar(&i64s, "i64s", nil, "int64 slice")
	root.PersistentFlags().Float64SliceVar(&f64s, "f64s", nil, "float64 slice")
	root.PersistentFlags().BoolSliceVar(&bools, "bools", nil, "bool slice")
	root.PersistentFlags().DurationSliceVar(&durs, "durs", nil, "duration slice")

	var sm map[string]string
	var im map[string]int
	root.PersistentFlags().StringToStringVar(&sm, "kvs", nil, "string-to-string map")
	root.PersistentFlags().StringToIntVar(&im, "metrics", nil, "string-to-int map")

	var ip net.IP
	var ipMask net.IPMask
	var ipNet net.IPNet
	var bx []byte
	var b64 []byte
	root.PersistentFlags().IPVar(&ip, "ip", nil, "IP address")
	root.PersistentFlags().IPMaskVar(&ipMask, "mask", nil, "IP mask")
	root.PersistentFlags().IPNetVar(&ipNet, "net", net.IPNet{}, "IP network (CIDR)")
	root.PersistentFlags().BytesHexVar(&bx, "bx", nil, "hex bytes")
	root.PersistentFlags().BytesBase64Var(&b64, "b64", nil, "base64 bytes")

	var timeout time.Duration
	root.PersistentFlags().DurationVar(&timeout, "timeout", 0, "operation timeout")

	root.AddCommand(newGreetCmd(&name, &verbose, &tags))
	root.AddCommand(newGroupsCmd())
	root.AddCommand(newHooksCmd())
	root.AddCommand(newRequiredCmd())
	root.AddCommand(newArgsCmd())
	root.AddCommand(newNoOptCmd())
	root.AddCommand(newCustomHelpCmd())
	root.AddCommand(newSetFnCmd())
	root.AddCommand(newDocgenCmd(root))
	root.AddCommand(newComplProbeCmd())
	root.AddCommand(newRootHelpCmd())
	root.AddCommand(newMorSlicesCmd())

	return root
}

// Demonstrates pflag slice types vipvot didn't initially port:
// UintSlice, IPSlice, IPNetSlice. Hidden so the kitchen-sink help
// fixture stays stable.
func newMorSlicesCmd() *cobra.Command {
	var (
		uints []uint
		ips   []net.IP
		nets  []net.IPNet
	)
	cmd := &cobra.Command{
		Use:    "morslices",
		Hidden: true,
		Short:  "Demonstrates UintSlice / IPSlice / IPNetSlice",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "uints=%v ips=%v nets=%v\n", uints, ips, nets)
		},
	}
	cmd.Flags().UintSliceVar(&uints, "uints", nil, "uint slice")
	cmd.Flags().IPSliceVar(&ips, "ips", nil, "IP slice")
	cmd.Flags().IPNetSliceVar(&nets, "nets", nil, "IP-net (CIDR) slice")
	return cmd
}

// Demonstrates pflag's `NoOptDefVal` opt-in for `--no-foo` boolean
// negation. The vipvot kitchen-sink intentionally accepts `--no-foo`
// for any boolean; pflag rejects it unless `NoOptDefVal` is set on
// the flag. Also covers the literal `--no-foo` registration case.
func newNoOptCmd() *cobra.Command {
	var negatable, plain, notFoo bool
	cmd := &cobra.Command{
		Use:    "noopt",
		Hidden: true,
		Short:  "Demonstrates pflag NoOptDefVal opt-in for boolean negation",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "negatable=%t plain=%t not-foo=%t\n", negatable, plain, notFoo)
		},
	}
	cmd.Flags().BoolVar(&negatable, "negatable", false, "boolean with NoOptDefVal opt-in (--no-negatable accepted)")
	cmd.Flags().BoolVar(&plain, "plain", false, "boolean without opt-in (--no-plain rejected)")
	cmd.Flags().BoolVar(&notFoo, "not-foo", false, "literally registered as `not-foo`")
	// NoOptDefVal opts negatable in: pflag will accept `--no-negatable`
	// (and `--negatable` standalone) and bind to the bool.
	if f := cmd.Flags().Lookup("negatable"); f != nil {
		f.NoOptDefVal = "true"
	}
	return cmd
}

// Demonstrates `SetHelpCommand` — the user replaces cobra's auto-injected
// help command with one of their own. Cobra's default help is registered
// via InitDefaultHelpCmd and is visible (listed) by default; the override
// path is documented but rarely exercised, so we capture both shapes.
func newCustomHelpCmd() *cobra.Command {
	parent := &cobra.Command{
		Use:    "customhelp",
		Hidden: true,
		Short:  "Demonstrates SetHelpCommand override",
	}
	parent.AddCommand(&cobra.Command{
		Use:   "child",
		Short: "Child of customhelp",
		Run:   func(cmd *cobra.Command, args []string) {},
	})
	custom := &cobra.Command{
		Use:   "help [topic]",
		Short: "Custom help command",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "custom help for %v\n", args)
		},
	}
	parent.SetHelpCommand(custom)
	return parent
}

// Demonstrates programmatic `Flags().Set()` on a deprecated flag —
// captures whether pflag emits the deprecation warning when the value
// is set from code rather than argv.
func newSetFnCmd() *cobra.Command {
	var legacy string
	cmd := &cobra.Command{
		Use:    "setfn",
		Hidden: true,
		Short:  "Demonstrates Flags().Set() on a deprecated flag",
		PreRun: func(cmd *cobra.Command, args []string) {
			// Programmatic set — does pflag warn?
			_ = cmd.Flags().Set("legacy", "from-prerun")
		},
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "legacy=%s\n", legacy)
		},
	}
	cmd.Flags().StringVar(&legacy, "legacy", "", "deprecated flag")
	if err := cmd.Flags().MarkDeprecated("legacy", "use --modern instead"); err != nil {
		panic(err)
	}
	return cmd
}

// Builds a fresh cobra root demonstrating `SetHelpCommand` at the
// root level (where it actually replaces the auto-injected help).
// Hidden so it doesn't pollute root help.
func newRootHelpCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "roothelp [args...]",
		Hidden: true,
		Short:  "Run a fresh cobra root with SetHelpCommand at the root",
		Args:   cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			fresh := &cobra.Command{Use: "freshtool", Short: "fresh tool with custom root help"}
			fresh.AddCommand(&cobra.Command{Use: "noop", Short: "no-op", Run: func(c *cobra.Command, a []string) {}})
			custom := &cobra.Command{
				Use:   "help [topic]",
				Short: "Custom root help command",
				Run: func(c *cobra.Command, a []string) {
					fmt.Fprintf(c.OutOrStdout(), "custom-root-help args=%v\n", a)
				},
			}
			fresh.SetHelpCommand(custom)
			fresh.SetArgs(args)
			fresh.SetOut(cmd.OutOrStdout())
			fresh.SetErr(cmd.ErrOrStderr())
			fresh.CompletionOptions.DisableDefaultCmd = true
			return fresh.Execute()
		},
	}
	return cmd
}

// Builds a fresh cobra root with cobra's default `completion` subcommand
// enabled (the kitchen-sink root has DisableDefaultCmd set to keep
// shell-completion machinery out of the help fixtures). Used to capture
// the help output of the auto-injected `completion` and per-shell
// generators — particularly the `--no-descriptions` flag.
//
// Hidden so it doesn't pollute root help.
func newComplProbeCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "complprobe [shell]",
		Hidden: true,
		Short:  "Emit `completion [shell] --help` from a fresh cobra root",
		Args:   cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			fresh := &cobra.Command{Use: "freshtool", Short: "fresh tool for completion probing"}
			// Add at least one runnable child so cobra renders a normal help block.
			fresh.AddCommand(&cobra.Command{Use: "noop", Run: func(cmd *cobra.Command, args []string) {}})
			// Force cobra to attach its default `completion` subcommand
			// even if DisableDefaultCmd were set elsewhere; default state
			// is on.
			fresh.InitDefaultCompletionCmd()
			invocation := []string{"completion"}
			if len(args) == 1 {
				invocation = append(invocation, args[0])
			}
			invocation = append(invocation, "--help")
			fresh.SetArgs(invocation)
			fresh.SetOut(cmd.OutOrStdout())
			fresh.SetErr(cmd.ErrOrStderr())
			return fresh.Execute()
		},
	}
	return cmd
}

func newGreetCmd(name *string, verbose *int, tags *[]string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "greet [target]",
		Short: "Print a greeting",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			target := *name
			if len(args) == 1 {
				target = args[0]
			}
			fmt.Fprintf(cmd.OutOrStdout(), "hello, %s\n", target)
			if *verbose > 0 {
				fmt.Fprintf(cmd.OutOrStdout(), "verbose=%d\n", *verbose)
			}
			if len(*tags) > 0 {
				fmt.Fprintf(cmd.OutOrStdout(), "tags=%s\n", strings.Join(*tags, "|"))
			}
			labels, _ := cmd.Flags().GetStringArray("label")
			if len(labels) > 0 {
				fmt.Fprintf(cmd.OutOrStdout(), "labels=%s\n", strings.Join(labels, "|"))
			}
			return nil
		},
	}
	return cmd
}

func newGroupsCmd() *cobra.Command {
	var (
		fileFlag, urlFlag string
		userFlag, passwd  string
		jsonOut, yamlOut  bool
	)

	cmd := &cobra.Command{
		Use:   "groups",
		Short: "Demonstrates flag-group constraints",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Fprintln(cmd.OutOrStdout(), "ok")
			return nil
		},
	}

	cmd.Flags().StringVar(&fileFlag, "file", "", "read from file")
	cmd.Flags().StringVar(&urlFlag, "url", "", "read from URL")
	cmd.Flags().StringVar(&userFlag, "user", "", "username")
	cmd.Flags().StringVar(&passwd, "password", "", "password")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "JSON output")
	cmd.Flags().BoolVar(&yamlOut, "yaml", false, "YAML output")

	cmd.MarkFlagsMutuallyExclusive("file", "url")
	cmd.MarkFlagsRequiredTogether("user", "password")
	cmd.MarkFlagsOneRequired("json", "yaml")

	return cmd
}

// Hidden helper that emits cobra/doc-formatted output for a target
// command path, so vipvot's doc-generator tests can capture cobra's
// reference rendering as snapshot fixtures.
func newDocgenCmd(root *cobra.Command) *cobra.Command {
	cmd := &cobra.Command{
		Use:    "docgen <format> [command path...]",
		Hidden: true,
		Args:   cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			format := args[0]
			path := args[1:]
			target := root
			if len(path) > 0 {
				t, _, err := root.Find(path)
				if err != nil {
					return err
				}
				target = t
			}
			switch format {
			case "markdown":
				return doc.GenMarkdown(target, os.Stdout)
			case "yaml":
				return doc.GenYaml(target, os.Stdout)
			case "rest":
				return doc.GenReST(target, os.Stdout)
			case "man":
				return doc.GenMan(target, &doc.GenManHeader{Title: "ORACLE", Section: "1"}, os.Stdout)
			case "bash":
				return root.GenBashCompletionV2(os.Stdout, true)
			case "zsh":
				return root.GenZshCompletion(os.Stdout)
			case "fish":
				return root.GenFishCompletion(os.Stdout, true)
			case "powershell":
				return root.GenPowerShellCompletion(os.Stdout)
			case "powershell-desc":
				return root.GenPowerShellCompletionWithDesc(os.Stdout)
			default:
				return fmt.Errorf("unknown format %q", format)
			}
		},
	}
	return cmd
}

func newArgsCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "args", Short: "Demonstrates Args validators"}

	cmd.AddCommand(&cobra.Command{
		Use:  "noargs",
		Args: cobra.NoArgs,
		Run:  func(cmd *cobra.Command, args []string) {},
	})
	cmd.AddCommand(&cobra.Command{
		Use:  "min2",
		Args: cobra.MinimumNArgs(2),
		Run:  func(cmd *cobra.Command, args []string) {},
	})
	cmd.AddCommand(&cobra.Command{
		Use:  "max2",
		Args: cobra.MaximumNArgs(2),
		Run:  func(cmd *cobra.Command, args []string) {},
	})
	cmd.AddCommand(&cobra.Command{
		Use:  "exact3",
		Args: cobra.ExactArgs(3),
		Run:  func(cmd *cobra.Command, args []string) {},
	})
	cmd.AddCommand(&cobra.Command{
		Use:  "range",
		Args: cobra.RangeArgs(1, 3),
		Run:  func(cmd *cobra.Command, args []string) {},
	})
	cmd.AddCommand(&cobra.Command{
		Use:        "validonly",
		Args:       cobra.OnlyValidArgs,
		ValidArgs:  []string{"alpha", "beta", "gamma"},
		ArgAliases: []string{"a", "b", "g"},
		Run:        func(cmd *cobra.Command, args []string) {},
	})

	return cmd
}

func newRequiredCmd() *cobra.Command {
	var (
		input    string
		level    int
		oldFlag  string
	)
	cmd := &cobra.Command{
		Use:   "required",
		Short: "Demonstrates required, hidden, and deprecated flags",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "input=%s level=%d\n", input, level)
		},
	}
	cmd.Flags().StringVar(&input, "input", "", "input path")
	cmd.Flags().IntVar(&level, "level", 0, "level")
	cmd.Flags().StringVar(&oldFlag, "old", "", "the old flag")
	cmd.Flags().StringVar(&oldFlag, "secret", "", "secret token")
	if err := cmd.MarkFlagRequired("input"); err != nil {
		panic(err)
	}
	if err := cmd.MarkFlagRequired("level"); err != nil {
		panic(err)
	}
	if err := cmd.Flags().MarkDeprecated("old", "use --new instead"); err != nil {
		panic(err)
	}
	if err := cmd.Flags().MarkHidden("secret"); err != nil {
		panic(err)
	}
	return cmd
}

func newHooksCmd() *cobra.Command {
	emit := func(label string) func(cmd *cobra.Command, args []string) {
		return func(cmd *cobra.Command, args []string) {
			fmt.Fprintln(cmd.OutOrStdout(), label)
		}
	}

	parent := &cobra.Command{
		Use:                "hooks",
		Short:              "Demonstrates the five-stage hook chain",
		PersistentPreRun:   emit("parent.persistentPreRun"),
		PersistentPostRun:  emit("parent.persistentPostRun"),
	}

	child := &cobra.Command{
		Use:     "child",
		Short:   "child command",
		PreRun:  emit("child.preRun"),
		PostRun: emit("child.postRun"),
		Run:     emit("child.run"),
	}

	parent.AddCommand(child)
	return parent
}
