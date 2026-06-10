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

**The emitter works for the core ST subset.** All four shipped examples
compile to C++17 that builds with clang/g++ against the vendored runtime and
runs correctly — verified end to end by the test suite (42 checks: golden
output landmarks mirroring the TypeScript original's tests, plus
compile-and-run binaries).

```lisp
(asdf:load-system "strucpp-cpp")
(strucpp-cpp:compile-st-file #p"examples/blink.st")
;; writes blink.hpp + blink.cpp next to the source
```

```sh
c++ -std=c++17 -Iruntime/include -I. blink.cpp main.cpp -o blink
```

Output conventions match the original: upcased identifiers, one class per
FB/PROGRAM with public `IEC_*` members, declared initializers in the
constructor, the body as `void operator()()`, FB calls lowered to
`T1.IN = …; T1(); Q = T1.Q;`, `T#500ms` → `500000000LL` nanoseconds.

**Standard FBs are not special-cased**: when a program references `TON`,
`CTU`, `R_TRIG`, `SR`, …, their ST sources (vendored under `stdfb/`, from the
original's `iec-standard-fb` library) are parsed and emitted alongside user
code. Timers read the runtime's virtual cycle clock (`TIME()` /
`__CURRENT_TIME_NS`), so generated programs are deterministic and steppable —
advance the clock yourself in your `main()`.

### Run the tests

```lisp
(ql:quickload "fiveam")
(asdf:test-system "strucpp-cpp")   ; needs a C++ compiler on PATH for the e2e tests
```

## Porting plan (mapping the TypeScript original)

| TypeScript module | CL home | Status |
|---|---|---|
| `frontend/lexer.ts` | STruCpp-cl `src/lexer.lisp` | ✅ done |
| `frontend/parser.ts`, `ast.ts`, `ast-builder.ts` | STruCpp-cl `src/parser.lisp`, `src/ast.lisp` | ✅ core subset |
| `semantic/*` | STruCpp-cl (planned `src/sema.lisp`) | ⏳ dynamic checks only |
| `backend/codegen.ts` | `src/codegen.lisp` | ✅ core subset |
| `backend/type-codegen.ts`, `codegen-utils.ts` | `src/codegen.lisp` (split when it grows) | ✅ elementary types |
| `backend/test-main-gen.ts`, REPL gen | later | — |
| `src/runtime/include/*.hpp` (C++ runtime) | vendored **verbatim** under `runtime/include/` | ✅ |
| `libs/sources/iec-standard-fb/*.st` | vendored under `stdfb/`, auto-bundled when referenced | ✅ |
| `il/*`, `library/*` (.stlib), VS Code extension | not planned for the port | — |

### Next steps

1. **Composite types** — `STRUCT`/`ENUM`/`ARRAY` emission
   (`type-codegen.ts`'s territory; blocked on frontend support).
2. **Located variables** — `AT %QX0.0` currently emits as a plain member with
   a comment; the original uses `iec_located.hpp`.
3. **Test-runner generation** — `--test` mode emitting a main() that runs
   ST-written TEST blocks (`test-main-gen.ts`).
4. **Line directives** — `#line` mapping back to ST source for debugging,
   like the original's line maps.
