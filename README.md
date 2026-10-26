# ruby-c-apis

Finds which public CRuby C API functions can raise (longjmp), by walking the call graph of LLVM IR.

- Tool: [`script/raise_survey/`](script/raise_survey/)
- Spec: [`docs/spec.md`](docs/spec.md)
- Results: <https://takahashim.github.io/ruby-c-apis/> ([`data.json`](https://takahashim.github.io/ruby-c-apis/data.json))
- Workflow: [`.github/workflows/raise-survey.yml`](.github/workflows/raise-survey.yml)

[![raise-survey](https://github.com/takahashim/ruby-c-apis/actions/workflows/raise-survey.yml/badge.svg)](https://github.com/takahashim/ruby-c-apis/actions/workflows/raise-survey.yml)

## Usage

```sh
ruby script/raise_survey/run.rb --release 3.4.9 --work work --out out
ruby script/raise_survey/survey.rb --inputs out --out site
open site/index.html
```

See [`script/raise_survey/README.md`](script/raise_survey/README.md) for requirements and CI.

Japanese: [README.ja.md](README.ja.md)
