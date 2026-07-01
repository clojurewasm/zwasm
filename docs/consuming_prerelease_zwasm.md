# Consuming pre-release zwasm reproducibly (for cljw / ClojureWasmFromScratch and others)

> **Doc-state**: ACTIVE. Audience: any downstream that depends on `zwasm` while it
> is still pre-`v1`-parity / pre-`v2.0.0` final — primarily cljw (`build.zig.zon`
> `.zwasm`). Answers: *"how do I reference zwasm so it also builds for others,
> reproducibly?"*

## TL;DR

**Pin an immutable, pushed ref — a git tag or a specific commit on `main` — plus
the content hash Zig records.** v2 now lives on `main` and carries prerelease tags
(`v2.0.0-alpha.*`, `v2.0.0-rc.1`, …). Prefer a tag; a `main` commit SHA is
equivalent for reproducibility (a tag is just a human-friendly *name* for a
commit, and Zig's package manager pins by the content `.hash` either way). The two
things that DO break other people's builds:

1. `.path = "../zwasm"` — a **local filesystem** ref. Unpublishable; anyone who
   clones cljw without your local zwasm tree fails immediately. Fine for local
   co-development, but it MUST change before cljw is pushed for others.
2. A **bare moving branch ref** (`#main`) with no recorded content hash — a moving
   target; a re-`zig fetch --save` re-pins to whatever `main` HEAD is then.
   Non-reproducible. Pin a tag or a fixed commit, never the branch name alone.

## Situation

- zwasm dev happens on `main` (`git@github.com:clojurewasm/zwasm.git`), with
  prerelease tags cut by the user (tag/publish are user-only, ADR-0156).
  **`--force` is forbidden** (project rule) → every pushed commit stays fetchable
  forever; history is append-only, so a pinned tag/commit never disappears.
- cljw's `build.zig.zon` `.zwasm` is **lazy** (`b.lazyDependency`; only `-Dwasm` /
  `-Dzwasm-spike` resolve it — the default build + gate never fetch it). Its
  "proper" pinned form is a dogfood tag (e.g. `v2.0.0-rc.1`); switch it to `.path`
  only for relative-path co-development.
- cljw consumes zwasm **interp-only** (the Zig facade + C-API never make a JIT
  instance). The interp/C-API/facade surface is additive-stable, so bumping the
  pin forward across prerelease tags is low-risk.

## Policy / approach

To let others build cljw reproducibly:

1. **Pin a tag (preferred) or a specific `main` commit — not the branch name, not
   `.path`.** In cljw's `build.zig.zon`:
   ```zig
   .zwasm = .{
       // preferred: an immutable prerelease tag
       .url = "git+https://github.com/clojurewasm/zwasm.git?ref=v2.0.0-rc.1#<COMMIT_SHA>",
       // or a bare main commit — functionally identical:
       // .url = "git+https://github.com/clojurewasm/zwasm.git#<COMMIT_SHA>",
       .hash = "<content-hash zig fetch records>",
       .lazy = true,
   },
   ```
   Produce it with
   `zig fetch --save=zwasm "git+https://github.com/clojurewasm/zwasm.git?ref=v2.0.0-rc.1"`.
   The recorded `.hash` is what makes it reproducible — Zig validates fetched
   content against it; a moved ref would hash-mismatch rather than silently drift.
2. A **commit-hash pin ≡ a tag pin** for reproducibility. Prefer the tag for
   readability (the diff shows a version, not a hex blob); fall back to a bare
   `main` commit when you need a fix that lands between tags.

## Requirements / caveats (true for tag-pin AND commit-pin)

- [x] **Pushed**: the pinned tag/commit must be on `origin` (`main`). Verify it
  exists on origin before pinning.
- [x] **No force-push** (project rule) → the commit never disappears.
- [ ] **Read access** to `github.com/clojurewasm/zwasm` for whoever builds cljw
  (public repo or granted access). The git+https URL + their git creds. *This is
  the one genuinely external requirement.*
- [ ] **Zig 0.16.0** toolchain parity on the builder's machine (orthogonal to the
  pin; the same constraint a tag carries).
- [ ] **Transitive deps**: fetching zwasm also fetches zwasm's own deps. Today
  that is only `zlinter` (`git+...#<sha>` + hash — already reproducible) and it is
  a lint-time dep; confirm it stays out of the consumer's required graph (lazy /
  not imported by the embedding API path) so a consumer isn't forced to fetch it.

## Recommendation

- **For cljw co-development now**: keep `.path` (fast local iteration) — but it is
  NOT pushable.
- **Before pushing cljw for others to build**: swap `.path` → a tag pin (above),
  or a bare `main` commit pin if you need an inter-tag fix. That alone prevents
  "doesn't build for others".
- **Track newer prerelease tags** as they are cut (user-only): bump the pin to the
  latest tag your consumer needs. Same reproducibility, friendlier diff than a
  moving branch ref.
