# Specification

Japanese: [spec.ja.md](spec.ja.md)

## Goal

- Determine whether each public CRuby C API function can reach a `longjmp` (i.e. raise), and provide that information.
- "Does not raise" means: no path to an escape point for any arguments, in every surveyed release and config.
- Conditionally safe functions are reported as "can raise".

## Scope

- Releases: stable releases from 3.3.0 on, plus Ruby HEAD. No previews or RCs. Default set: `script/raise_survey/releases.txt`.
- Configs: `linux-x86_64`, `macos-arm64`. Built with `-O0`.
- Public API: functions declared by the headers in `include/` under the `rb_` / `ruby_` / `st_` / `onig` namespaces.
  - Headers under `ruby/internal/` are included: they are installed and part of the public API.
  - Macros are not listed; the functions they expand to are.
  - `static inline` functions get a generated forwarding wrapper that serves as the root of the call graph.

## Pipeline

1. Pick releases (`fetch.rb`, `prepare.rb`).
2. Build `miniruby` and the static library with a clang wrapper that emits `.bc` next to each `.o` (`ccbc.rb`, `build.rb`).
3. `llvm-link` + `llvm-dis` into one text IR.
4. Extract the public API from the header AST (`api.rb`).
5. Build the call graph and walk it backwards from the escape points (callee → caller) (`analyze.py`).
6. Aggregate across releases and configs into `index.html` and `data.json` (`survey.rb`).

## Analysis

Call relations (caller → callee, the edges of the call graph):
- Direct calls.
- Functions passed by name as call arguments (callbacks).
- Indirect calls: `any` (default) lets any address-taken function be the target; `typed` requires a roughly matching signature.

Escape points:
- Any name containing `longjmp`, `llvm.eh.sjlj.longjmp`, `rb_ec_tag_jump`.

Constant-argument pruning:
- A function that branches on an integer argument, or forwards one, is specialized per set of constant arguments (shown as `f{arg4=1}` in paths).
- Only blocks reachable under those constants keep their calls. Unknown values keep both branches.
- Example: `ruby_xfree` passes `MEMOP_TYPE_FREE`, and `objspace_malloc_increase_body` starts a GC only for `MEMOP_TYPE_MALLOC`, so `ruby_xfree` is not considered to call the GC.
- Trusted only for arguments spilled once to an alloca and never rewritten. Struct fields and arithmetic are not tracked.

Result per function and run:
- `no_path`, `raises` (with an example `path` and `target`), `not_defined`, `unsupported_inline`.
- Overall: all `no_path` → "no path in every release"; any `raises` → "can raise".

Controls:
- `rb_ary_push`, `rb_jump_tag`, `rb_exc_raise`, `rb_ary_new_capa` must have a path. Otherwise the report shows a warning and results must not be trusted.

## Limits

- No path holds only for the analyzed build. Extension callbacks and `dlopen`ed code are not covered.
- Results depend on OS and configure options (JIT, MMTk, ...). Other GC implementations are not analyzed.
- Remaining false positives come from untracked values (flags in structs, hash function pointers). A human must read the path.
- Raising inside external libraries (libc, ...) is not modeled.
- `NoMemoryError` is rarely documented in headers; this analysis covers it, but is not a proof.
