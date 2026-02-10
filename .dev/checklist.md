# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Known gaps from CW extraction

| ID   | Item                                | Source     | Trigger                               |
|------|-------------------------------------|------------|---------------------------------------|
| W1   | table.copy cross-table support      | CW F136    | Currently stub in CW                  |
| W2   | table.init implementation           | CW F137    | Currently stub in CW                  |
| ~~W3~~| ~~Error type design~~ RESOLVED      | Extraction | No EvalError remains; Zig inferred error sets are appropriate |
| W4   | WASI fd_readdir implementation      | CW gap     | WASI P1 completion (Stage 2)          |
| W5   | WASI sock_* family                  | CW gap     | WASI P1 completion (Stage 2)          |
| W6   | Wast test runner                    | New        | Stage 2 spec conformance              |
| W7   | Component Model basics              | New        | Stage 3                               |
