# ruby-c-apis

CRuby の公開 C API が raise（longjmp）しうるかを、LLVM IR の呼び出しグラフから
機械的に調べるツールです。計画は [`notes/raise_survey_plan.ja.md`](notes/raise_survey_plan.ja.md)
にあります。

- ツール本体: [`script/raise_survey/`](script/raise_survey/)
- GitHub Actions: [`.github/workflows/raise-survey.yml`](.github/workflows/raise-survey.yml)
- 公開ページ: GitHub Pages（`https://OWNER.github.io/REPO/`）

## 使い方

```sh
ruby script/raise_survey/run.rb --release 3.4.9 --work work --out out
ruby script/raise_survey/survey.rb --inputs out --out site
open site/index.html
```

詳しい前提、CI の設定、出力形式、限界は
[`script/raise_survey/README.md`](script/raise_survey/README.md) を参照してください。

## GitHub Actions

`main` への push、手動実行、毎月のスケジュールで走ります。結果は GitHub Pages に
`index.html` と `data.json` としてデプロイされます。初回はリポジトリの
**Settings → Pages → Source** を **GitHub Actions** にしてください。
