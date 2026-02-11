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
| W4   | WASI fd_readdir implementation      | CW gap     | WASI P1 completion (Stage 2)          |
| W5   | WASI sock_* family                  | CW gap     | WASI P1 completion (Stage 2)          |
| W7   | Component Model basics              | New        | Stage 3                               |
| W8   | Cross-module type signature matching | E2E 5E     | call_indirect across modules (5 fails) |
| W9   | Cross-module table func ref remap   | E2E 5E     | table_copy_on_imported_tables (4 fails)|
