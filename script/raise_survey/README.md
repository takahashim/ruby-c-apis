# CRuby C API raise survey

`notes/raise_survey_plan.ja.md` の計画を実行するためのツールと、GitHub Actions で
結果を HTML として公開するワークフローです。

生成物は GitHub Pages に `index.html` と `data.json` として公開されます。

## 何をするか

1. ruby-lang.org の `cache.ruby-lang.org/pub/ruby/index.txt` から安定版を選ぶ
2. 各リリースを clang でビルドし、`libruby-*-static.a` の各オブジェクトと一緒に
   LLVM bitcode (`.bc`) を生成する
3. `llvm-link` で 1 つのモジュールにまとめ、`llvm-dis` でテキスト IR にする
4. インストール対象のヘッダから公開 C API の宣言を取り出す
5. `static inline` 関数には、引数をそのまま渡すだけのラッパーを生成する
6. 呼び出しグラフを逆にたどり、`longjmp` 系の脱出点に到達する関数を求める
7. リリースと構成をまたいで集計し、HTML と JSON を出力する

「raise しない」は「何を渡されても raise しない」の意味です。引数の値や条件分岐は
追わないため、条件付きで安全な関数は「raise しうる」に分類されます。これは
`NON_RAISING` の定義に合わせた安全側の扱いです。

## ローカルで 1 リリースを動かす

必要なもの:

- Ruby 3.3 以降（スクリプト本体。CRuby のビルドには使いません）
- Python 3.9 以降
- clang（bitcode を出せるもの）
- `llvm-link` / `llvm-dis`
- make、tar、curl
- HEAD を調べる場合のみ: git、autoconf、automake、libtool、bison 3 以降

macOS では Homebrew の LLVM を使います。Apple clang でもビルドはできますが、
Xcode 26 / macOS 26 の Apple clang 21 でビルドした Ruby 3.4.9 が起動直後に
落ちることを確認しているため、CI でも Homebrew LLVM を使います。

```sh
brew install llvm autoconf automake libtool bison
export PATH="$(brew --prefix bison)/bin:$PATH"
export PATH="$(brew --prefix llvm)/bin:$PATH"
export CCBC_REAL_CC="$(brew --prefix llvm)/bin/clang"

ruby script/raise_survey/run.rb \
  --release 3.4.12 \
  --config macos-arm64 \
  --work work \
  --out out \
  --jobs 8
```

Linux:

```sh
sudo apt-get install -y build-essential clang llvm
ruby script/raise_survey/run.rb \
  --release 3.4.12 \
  --config linux-x86_64 \
  --work work \
  --out out \
  --jobs 8
```

HTML を作る:

```sh
ruby script/raise_survey/survey.rb \
  --inputs out \
  --out site \
  --commit "$(git rev-parse HEAD)" \
  --repo-url https://github.com/OWNER/REPO
```

`site/index.html` をブラウザで開いてください。

## GitHub Actions

`.github/workflows/raise-survey.yml` が次の 3 ジョブを実行します。

| ジョブ | 内容 |
|---|---|
| `test` | Ruby/Python の構文チェックと、フィクスチャからの HTML 生成 |
| `prepare` | リリース一覧と runner の matrix を作る |
| `survey` | release × config ごとにビルド・解析し、JSON を artifact に上げる |
| `publish` | artifact を集計して GitHub Pages にデプロイする |

### 実行方法

- `main` への push（`script/raise_survey/**` などを変更したとき）
- 手動実行 `workflow_dispatch`
  - `releases`: カンマ区切り（空なら `script/raise_survey/releases.txt`）
  - `all_releases`: 3.3 以降の全安定版と HEAD を調査する
  - `indirect`: `any`（既定、最も保守的）または `typed`
- 毎月 1 日のスケジュール実行（全安定版）

初回だけ、リポジトリの **Settings → Pages → Build and deployment → Source** を
**GitHub Actions** にしてください。ワークフロー内の `actions/configure-pages` は
Pages が無効なら有効化を試みますが、リポジトリの設定によっては手動が必要です。

公開 URL は `https://OWNER.github.io/REPO/` です。

### 対象リリース

`script/raise_survey/releases.txt` に最新パッチ版（3.3.13、3.4.12、4.0.9）と
HEAD を置いています。全リリースは `workflow_dispatch` の `all_releases`、または

```sh
ruby script/raise_survey/prepare.rb --all
```

で確認できます。プレリリース（preview / rc）は含めません。

`HEAD` は GitHub の `ruby/ruby` master を、実行時点の commit SHA に固定して
取得します。git チェックアウトには `configure` が含まれないため、取得後に
`autogen.sh`（autoreconf）で生成します。結果には `build.head_sha` が入ります。

## 出力

`data.json` の各関数は次の形です。

```json
{
  "name": "rb_array_len",
  "header": "ruby/internal/core/rarray.h",
  "internal": true,
  "kind": "inline",
  "results": {
    "3.4.12|macos-arm64|any": { "status": "no_path" },
    "3.4.12|linux-x86_64|any": { "status": "no_path" }
  },
  "scope": "internal",
  "overall": "no_path_all",
  "raise_count": 0,
  "no_path_count": 2,
  "unanalyzed_count": 0
}
```

- `status: no_path`: そのビルドの IR に脱出点への経路がない
- `status: raises`: 経路がある。`path` に例、`target` に到達した脱出点
- `status: not_defined`: ヘッダにあるが、そのビルドの `libruby` に実体がない
- `status: unsupported_inline`: `static inline` だがラッパーを生成できなかった
- `scope: official`: 宣言が `ruby/internal/` 以外の公式ヘッダにある
- `scope: internal`: 宣言が `ruby/internal/` 配下にある
- `scope: mixed`: 版によって official / internal が変わる

HTML の表では、全実行で `no_path` のものを「全リリースで経路なし」、1 つでも
`raises` のものを「raise しうる」と表示します。行をクリックすると、リリース ×
構成ごとの判定と経路の例が出ます。

「API 範囲」の列とフィルタで、公式ヘッダ（`ruby/internal/` 以外）と
`ruby/internal/` 配下を分けられます。同じ関数でも版によって宣言位置が変わる
場合は「混在」になります。

## 解析の詳細

### 根（公開 API）

ヘッダの `FunctionDecl` から `rb_` / `ruby_` で始まる関数を取ります。
`static inline` は実体がライブラリにないため、次のようなラッパーを生成します。

```c
__attribute__((noinline, used))
long survey_inline_rb_array_len(VALUE p0) {
  return rb_array_len(p0);
}
```

ラッパーは実行しません。呼び出しグラフの根としてだけ使います。可変長引数など、
そのまま転送できない関数は `unsupported_inline` になります。

### 辺

- 直接呼び出し
- 呼び出しの引数として名前を渡された関数（コールバック）
- 間接呼び出し

間接呼び出しは既定 (`--indirect any`) で「アドレスを取られた関数のどれでも
呼びうる」とします。`typed` は呼び出し側の引数の型と、定義側の型が粗く一致する
ものだけを許します。`typed` は偽陽性を減らしますが、完全な型一致ではありません。

### 脱出点

- `longjmp` を名前に含む関数（`_longjmp`、`__longjmp_chk`、`siglongjmp` など）
- `llvm.eh.sjlj.longjmp`
- `rb_ec_tag_jump`

到達可能性は脱出点から逆方向に伝播させ、各根について最短の経路を 1 つ保存します。

### 対照実験

`rb_ary_push`、`rb_jump_tag`、`rb_exc_raise`、`rb_ary_new_capa` が経路ありと
判定されることを確認します。1 つでも失敗した実行があると、HTML の上部に警告が
出ます。この場合は解析結果を信用しないでください。

## 計画との違い

- `make install` はしません。ヘッダはソースツリーの `include/` と、ビルド時の
  `.ext/include/<arch>/ruby/config.h` を使います。`make install` は拡張ライブラリも
  ビルドするため、OpenSSL など無関係な失敗で止まりやすいからです。
- ビルド対象は `miniruby` と `Makefile` の `LIBRUBY_A`（Linux は
  `libruby-static.a`、macOS は `libruby.<major>.<minor>-static.a`）だけです。
  拡張ライブラリは C API の実体を持たないので解析に含めません。
- macOS は Homebrew LLVM の clang を使います。Apple clang の bitcode は LLVM
  ツールで読めますが、環境によって Ruby 本体のビルドが壊れるためです。
- `-O0` でビルドします。最適化で呼び出しが消えるのを避け、解析を保守的にするためです。
- HEAD は安定版ではないため、結果は「その時点の master」に対する参考値です。
  再実行すると commit が変わります。比較には `build.head_sha` を使ってください。

## 限界

- 経路がないことは、そのビルドのコードについてだけ言えます。拡張が登録する
  コールバックや `dlopen` で後から読み込まれるコードは含みません。
- OS、configure オプション（JIT、`--with-mmtk` など）でコードも longjmp の名前も
  変わります。結果は構成ごとに出し、版と構成の積集合を安全とみなします。
- 解析は引数の値や条件分岐を追わないため、偽陽性を含みます。偽陽性は人が経路を
  読んで確認する必要があります。
- 外部ライブラリの中で raise する関数（libc など）は対象外です。
- `NoMemoryError` はヘッダの doc コメントにほとんど書かれません。この解析は
  その不足を補うものですが、証明ではありません。

## ファイル

| ファイル | 役割 |
|---|---|
| `fetch.rb` | リリース一覧の取得とソースの展開 |
| `prepare.rb` | GitHub Actions の matrix 生成 |
| `ccbc.rb` | clang のラッパー。`.o` の隣に `.bc` を出す |
| `build.rb` | configure、`miniruby` / `libruby-*-static.a` のビルド、bitcode の link |
| `api.rb` | ヘッダの AST から公開 API を抽出し、inline ラッパーを生成・コンパイル |
| `analyze.py` | IR から呼び出しグラフを作り、脱出点への到達可能性を判定 |
| `survey.rb` | リリース横断の集計と HTML / JSON の生成 |
| `run.rb` | 1 リリース・1 構成のオーケストレーション |
| `releases.txt` | push / 手動実行の既定リリース |
| `test/fixtures/` | HTML 生成のスモークテスト用データ |

## 注意

- このリポジトリのワークフローは GitHub Pages へ公開します。結果を公開したくない
  場合は `publish` ジョブを削除するか、artifact だけを残してください。
- `all_releases` は 37 リリース × 2 構成 = 74 ジョブになります。1 ジョブあたり
  数分かかるため、初回は trial の 3 リリースで確認することを勧めます。
