---
description: "libc dependency boundary — `std.c.*` calls are forbidden unless they fall into one of the 3 categories (necessary/replaceable/convenience) defined in ADR-0070. New `std.c.*` additions require an ADR justification."
paths:
  - "src/**/*.zig"
---

# libc dependency boundary

> **Status**: landed at §9.12-A (2026-05-19); enforced by
> `scripts/check_libc_boundary.sh` (functional A1) + `audit_scaffolding
> §G.5` (extension at §9.12-D). Justified by ADR-0070 (Accepted).
> Sample-migration of the 10 replaceable sites happens in §9.12-D.

## The rule

When adding a new `std.c.*` call site in Zig source, it must fall into one of
the 3 categories defined in ADR-0070:

| Category | Example | Handling |
|---|---|---|
| necessary | `sigsetjmp` / `siglongjmp` / `pthread_jit_write_protect_np` | OK; linking the upstream Zig stdlib issue is recommended |
| replaceable | `std.c.write` / `_exit` / `getenv` / `munmap` | NG — use `std.posix.*` / `process.Environ` |
| convenience | `std.heap.DebugAllocator` (Debug only) | OK only in Debug builds |

If a new site is required, an amendment to ADR-0070 (adding the new site to the necessary category) is mandatory.

## Before writing `std.c.<name>`, check first

- `std.posix.<name>` — whether a POSIX abstraction exists
- `std.Io.<name>` — Zig 0.16's Io abstraction
- `process.Environ` — for retrieving env vars
- The corresponding `std.os.linux.*` / `std.os.darwin.*` syscall wrapper

## Enforcement

- `scripts/check_libc_boundary.sh` — functional implementation at §9.12-A.
  `--gate` mode FAILs on any `replaceable` or `unclassified` site. The
  `unclassified` bucket catches NEW `std.c.*` / `@extern("c")` /
  `pthread_*` / `sigsetjmp` / `siglongjmp` / `sys_icache_invalidate`
  sites whose symbol is not on ADR-0070's `necessary`/`replaceable`/
  `convenience` lists.
- `audit_scaffolding §G.5` extension (lands in §9.12-D): periodic
  re-grep on the active branch.
- **ROADMAP §14** forbidden list has the "Unconscious libc fanout"
  entry (added at §9.12 collab gate close, 2026-05-19).

## Grep-able anti-patterns

```sh
grep -nE 'std\.c\.(write|_exit|getenv|munmap|kill|fork|alarm|waitpid)\b' src/ test/
grep -nE '@extern\(\.\{[[:space:]]*\.library_name[[:space:]]*=[[:space:]]*"c"' src/ test/
grep -nE '\b(sigsetjmp|siglongjmp|pthread_jit|sys_icache_invalidate)\b' src/ test/
```

## Reviewer checklist

- [ ] Does the diff introduce a new `std.c.*` / `@extern("c")` /
      `pthread_*` site?
- [ ] If yes, is it in ADR-0070's `necessary` list? OK.
- [ ] Otherwise, has ADR-0070 been amended to add the new site to
      `necessary` (with a stdlib-equivalent issue link)?
- [ ] If the site is a `replaceable` (e.g. `std.c.write`), use the
      `std.posix.*` / `std.process.*` equivalent instead.

## Related

- ADR-0070 (libc dependency policy; 3-category classification + 16-site
  inventory; Accepted 2026-05-19)
- ADR-0067 (ubuntunote pivot; D-134 Rosetta — origin of libc reliability concerns)
- ADR-0071 §Q6 (Phase 9 substrate audit Q6 resolution)
- Master plan §3.6 / §5.3 §9.12-D (sample migration of 10 replaceable sites)
