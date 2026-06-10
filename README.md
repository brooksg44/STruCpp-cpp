# STruCpp-cpp

**IEC 61131-3 Structured Text → C++17 compiler in Common Lisp** — a port of
[STruCpp](https://github.com/brooksg44/STruCpp) (TypeScript) keeping its
mission: compile ST into readable C++17 you can build with any compiler.

The frontend (lexer, parser, AST) is **not** in this repo: it lives in the
sibling [STruCpp-cl](../STruCpp-cl) system, which also provides a tree-walking
interpreter. This system depends on it via ASDF and adds only the backend:

```
ST source ──[strucpp-cl: lexer → parser → AST]──▶ codegen (this repo) ──▶ .cpp/.hpp
                                            └───▶ interpreter (STruCpp-cl)
```

Both projects must live under a directory ASDF scans (e.g. `~/common-lisp/`).

## Status

**Scaffold.** The shared frontend parses all of the original repo's examples
(see STruCpp-cl, 87 tests passing); the C++ emitter is the next milestone.

```lisp
(asdf:load-system "strucpp-cpp")
(strucpp-cpp:compile-st-file #p"counter.st")   ; => error: codegen is milestone 2
```

## Porting plan (mapping the TypeScript original)

| TypeScript module | CL home | Status |
|---|---|---|
| `frontend/lexer.ts` | STruCpp-cl `src/lexer.lisp` | ✅ done |
| `frontend/parser.ts`, `ast.ts`, `ast-builder.ts` | STruCpp-cl `src/parser.lisp`, `src/ast.lisp` | ✅ core subset |
| `semantic/*` | STruCpp-cl (planned `src/sema.lisp`) | ⏳ dynamic checks only |
| `backend/codegen.ts` | `src/codegen.lisp` | 🔜 milestone 2 |
| `backend/type-codegen.ts`, `codegen-utils.ts` | `src/codegen.lisp` (split when it grows) | 🔜 |
| `backend/test-main-gen.ts`, REPL gen | later | — |
| `src/runtime/include/*.hpp` (C++ runtime) | reused **verbatim** from the original | — |
| `il/*`, `library/*`, VS Code extension | not planned for the port | — |

### Milestone 2 sketch (the emitter)

1. Type mapping: `BOOL→bool`, `INT→int16_t`, `DINT→int32_t`, `REAL→float`,
   `LREAL→double`, `TIME→` the original runtime's time type.
2. One C++ class per `FUNCTION_BLOCK`/`PROGRAM` (members from VAR blocks with
   initializers; body as a scan method), free functions for `FUNCTION`s.
3. Expression/statement emission with the original's precedence-aware
   parenthesization; standard FBs/functions resolve to the original's
   header-only runtime so generated code compiles with
   `g++ -std=c++17 -I<strucpp>/src/runtime/include`.
4. Golden tests: compile the four examples, diff against the TypeScript
   compiler's output, and `g++`-compile the result in CI.
