# raise_survey

Spec: [`docs/spec.md`](../../docs/spec.md)

## Requirements

- Ruby 3.3+ (scripts only), Python 3.9+
- clang that emits bitcode, `llvm-link`, `llvm-dis`
- make, tar, curl
- For HEAD: git, autoconf, automake, libtool, bison 3+

On macOS use Homebrew LLVM. Apple clang 21 (Xcode 26) builds a Ruby 3.4.9 that crashes at startup.

## Run one release

```sh
brew install llvm autoconf automake libtool bison   # macOS
export PATH="$(brew --prefix bison)/bin:$(brew --prefix llvm)/bin:$PATH"
export CCBC_REAL_CC="$(brew --prefix llvm)/bin/clang"

ruby script/raise_survey/run.rb --release 3.4.12 --config macos-arm64 --work work --out out --jobs 8
ruby script/raise_survey/survey.rb --inputs out --out site --repo-url https://github.com/OWNER/REPO
```

- Linux: `apt-get install build-essential clang llvm`, `--config linux-x86_64`.
- `--indirect any|typed` selects the indirect-call model.

## GitHub Actions

`.github/workflows/raise-survey.yml`: `test` → `prepare` → `survey` (release × config) → `publish` (GitHub Pages).

- Triggers: push to `main` touching the tool, `workflow_dispatch`, monthly schedule (all stable releases).
- Inputs: `releases` (comma-separated, default `releases.txt`), `all_releases`, `indirect`.
- First time: set **Settings → Pages → Source** to **GitHub Actions**.
- `all_releases` is about 74 jobs; try the default set first.
- `HEAD` is pinned to the commit SHA at run time (`build.head_sha` in the result); `configure` is generated with `autogen.sh`.

## Output

`data.json` entries:

```json
{
  "name": "rb_array_len", "header": "ruby/internal/core/rarray.h",
  "internal": true, "kind": "inline", "scope": "internal",
  "results": { "3.4.12|macos-arm64|any": { "status": "no_path" } },
  "overall": "no_path_all", "raise_count": 0, "no_path_count": 2, "unanalyzed_count": 0
}
```

## Differences from a plain install

- No `make install`: headers come from `include/` and `.ext/include/<arch>/ruby/config.h`.
- Only `miniruby` and `LIBRUBY_A` are built; extensions have no C API bodies.
- `-O0`, so optimization does not remove calls.

## Files

| File | Role |
|---|---|
| `fetch.rb` | release list, source download |
| `prepare.rb` | CI matrix |
| `ccbc.rb` | clang wrapper emitting `.bc` |
| `build.rb` | configure, build, link bitcode |
| `api.rb` | public API extraction, inline wrappers |
| `analyze.py` | call graph and reachability |
| `survey.rb` | aggregation, HTML / JSON |
| `run.rb` | one release × one config |
| `test/fixtures/` | smoke-test data for the report |
