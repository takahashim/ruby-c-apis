# ruby-c-apis

CRuby の公開 C API が raise（longjmp）しうるかを、LLVM IR の呼び出しグラフから機械的に調べます。

- ツール: [`script/raise_survey/`](script/raise_survey/)
- 仕様: [`docs/spec.ja.md`](docs/spec.ja.md)
- 結果: <https://takahashim.github.io/ruby-c-apis/>（[`data.json`](https://takahashim.github.io/ruby-c-apis/data.json)）

使い方は [README.md](README.md) と [`script/raise_survey/README.md`](script/raise_survey/README.md) を参照してください。
