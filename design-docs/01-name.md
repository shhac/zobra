# 01 — Name

## The name

**zobra** = **z** + **(c)obra**.

Two readings, both intended:

- **Zig + cobra.** The Zig port of cobra. The `z` prefix is the convention several Zig packages use (`zli`, `zigistry`, `zls`, `ziggy`); `cobra` is the thing being ported. Drop the `c` because it's also the Zig phoneme for "C-interop" and we don't want users to read this as a C wrapper.
- **A different snake.** Cobra is an elapid; the zobra is its phonetic cousin. A different language of the same library, the same way a TypeScript port (vipvot) is a different language of the same library.

The name lands on a `z` so it sorts at the bottom of `zig fetch --save` registries — that's a feature, not a bug, when most Zig package names cluster around `zig-`.

## Naming sweep

Confirmed unclaimed (as of bootstrapping this repo):

- **GitHub user `zobra`** is taken — repo will live under the author's user/org (`shhac/zobra`), not at `zobra/zobra`.
- **npm `zobra`** — unclaimed. Reserved against future packaging.
- **crates.io `zobra`** — unclaimed.
- **pkg.go.dev `github.com/shhac/zobra`** — n/a until first tag.
- **Zigistry** — no collision.

## Pronunciation

"ZOH-bruh" (first syllable stressed, like "cobra" with a `z`). Two syllables.

## Pluralisation

Avoid. It's "a CLI built with zobra," not "a zobra." If forced, "zobras" — but the package, not its consumers, is the named thing.

## Capitalisation

Lowercase in prose (`zobra`, like cobra and vipvot). PascalCase only for the type name in source (`pub const Command = ...`); the import name is `zobra`.

## Rejected alternatives

- **zcobra** — too literal, reads as "zee-cobra" not as a name. Three consonants in a row at the head.
- **zigobra** — five syllables, awkward to say, and reads as "Zig + obra" rather than "Zig + cobra" because the `c` collapses.
- **cobraz** — ends in `z`; sorts well; but reads as plural ("cobras" with a typo) and the suffix-z convention isn't used in Zig.
- **kobra** / **kobraz** — non-Latin spelling adds confusion without compensating value.
- **zobra-cli** — suffix is a hint that this is a CLI library, but cobra itself doesn't carry one and we want shape parity.

## Brand notes

- Logo direction (when one is needed): a snake in a `z` shape, or a `z` rendered as a coiled snake. Neither is needed for the bootstrap.
- The README leads with the cobra connection (`Zig port of spf13/cobra`) and only then explains the name — the function comes before the etymology for new readers.
