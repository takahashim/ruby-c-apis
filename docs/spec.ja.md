# 仕様

English: [spec.md](spec.md)

## 目的

- CRuby の公開 C API の各関数が `longjmp`（raise）に到達しうるかを判定し、その情報を提供する。
- 「raise しない」は、どの引数でも、調べた全リリース・全構成で非局所脱出関数への経路がないこと。
- 条件付きで安全な関数は「raise しうる」に分類する。

## 範囲

- リリース: 3.3 以降の保守中の各系列について、最初と最新のパッチ版と、Ruby HEAD（`script/raise_survey/releases.txt`）。プレリリースは除く。
  - 間のパッチ版は調べない。両端と同じ振る舞いと見なすが、保証はない。
  - 全安定版は手動実行（`all_releases`）で調べられる。
- 構成: `linux-x86_64`、`macos-arm64`。`-O0` でビルドする。
- 公開 API: `include/` のヘッダが宣言する `rb_` / `ruby_` / `st_` / `onig` の関数。
  - `ruby/internal/` 配下のヘッダも含める。インストールされる公開 API である。
  - マクロは列挙せず、展開先の関数を調べる。
  - `static inline` は、転送するだけのラッパーを生成して根にする。

## 流れ

1. リリースを選ぶ（`fetch.rb`、`prepare.rb`）。
2. clang のラッパーで `.o` と同時に `.bc` を出し、`miniruby` と静的ライブラリをビルドする（`ccbc.rb`、`build.rb`）。
3. `llvm-link` と `llvm-dis` で 1 つのテキスト IR にする。
4. ヘッダの AST から公開 API を抽出する（`api.rb`）。
5. 呼び出しグラフを作り、非局所脱出関数から呼び出し元へ逆向きにたどる（`analyze.py`）。
6. リリースと構成をまたいで集計し、`index.html` と `data.json` を出す（`survey.rb`）。

## 解析

呼び出し関係:
- 直接呼び出し。
- 引数として名前で渡された関数（コールバック）。
- 間接呼び出し。`any`（既定）はアドレスを取られた関数すべて、`typed` は署名が粗く一致するものだけ。

非局所脱出関数:
- 名前に `longjmp` を含む関数、`llvm.eh.sjlj.longjmp`、`rb_ec_tag_jump`。

定数引数による枝刈り:
- 整数引数で分岐する関数、またはその引数を渡す関数は、定数引数の組ごとに特殊化した関数を作る（経路では `f{arg4=1}`）。
- その定数で到達できるブロックの呼び出しだけを残す。値が分からなければ両方の分岐を残す。
- 例: `ruby_xfree` は `MEMOP_TYPE_FREE` を渡す。`objspace_malloc_increase_body` が GC を起こすのは `MEMOP_TYPE_MALLOC` のときだけなので、GC への呼び出し関係はない。
- 信用するのは、alloca に一度だけ退避され再代入されない引数だけ。構造体のフィールドや算術は追わない。

関数ごとの判定:
- `no_path`、`raises`（経路の例と `target` つき）、`not_defined`、`unsupported_inline`。
- 総合: 全実行で `no_path` なら「全リリースで経路なし」、1 つでも `raises` なら「raise しうる」。

対照実験:
- `rb_ary_push`、`rb_jump_tag`、`rb_exc_raise`、`rb_ary_new_capa` に経路があること。失敗したらレポートに警告が出る。その結果は信用しない。

## 限界

- 経路がないことは、解析したビルドについてだけ言える。拡張のコールバックや `dlopen` のコードは含まない。
- OS や configure オプション（JIT、MMTk など）で結果が変わる。標準以外の GC 実装は解析していない。
- 偽陽性は、追えない値（構造体内のフラグ、ハッシュ関数ポインタ）から残る。人が経路を読んで確認する。
- 外部ライブラリ（libc など）の中の raise は扱わない。
- `NoMemoryError` はヘッダにほとんど書かれない。この解析はそれを補うが、証明ではない。
