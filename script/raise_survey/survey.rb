#!/usr/bin/env ruby
# frozen_string_literal: true

# survey.rb -- aggregate per-release analysis JSON files and write the public
# HTML report.
#
# Usage:
#   ruby survey.rb --inputs out --out site [--commit SHA] [--repo-url URL]
#
# The HTML is self-contained (CSS and JavaScript inline) and embeds the same
# data as data.json, so it can be published with GitHub Pages without a build
# step or external assets.

require "cgi"
require "fileutils"
require "json"
require "optparse"
require "time"

module RaiseSurvey
  module Report
    module_function

    STATUS_LABELS = {
      "no_path" => "経路なし",
      "raises" => "raise しうる",
      "not_defined" => "未定義",
      "unsupported_inline" => "未解析 (inline)"
    }.freeze

    def version_key(version)
      version.split(".").map(&:to_i)
    end

    def load_runs(inputs)
      files = inputs.flat_map do |input|
        if File.directory?(input)
          Dir.glob(File.join(input, "**", "*.json"))
        else
          Dir.glob(input)
        end
      end
      files = files.reject do |path|
        base = File.basename(path)
        %w[data.json build_meta.json api.json index.json].include?(base)
      end

      runs = {}
      files.uniq.each do |path|
        begin
          data = JSON.parse(File.read(path))
        rescue JSON::ParserError, Errno::ENOENT
          next
        end
        next unless data.is_a?(Hash) && data["schema"] == 1 && data["functions"].is_a?(Array)

        key = [data["release"], data["config"], data["indirect"] || "any"].join("|")
        existing = runs[key]
        if existing.nil? || (data["generated_at"].to_s > existing["generated_at"].to_s)
          runs[key] = data
        end
      end
      runs.values.sort_by { |run| [version_key(run["release"].to_s), run["config"].to_s, run["indirect"].to_s] }
    end

    def build_data(runs, commit:, repo_url:, generated_at:)
      releases = runs.map { |run| run["release"] }.uniq.sort_by { |v| version_key(v.to_s) }
      configs = runs.map { |run| run["config"] }.uniq.sort
      run_keys = runs.map { |run| run_key(run) }

      by_name = {}
      omitted = 0
      runs.each do |run|
        key = run_key(run)
        run["functions"].each do |fn|
          name = fn["name"]
          next unless name

          entry = by_name[name] ||= {
            "name" => name,
            "header" => fn["header"],
            "kind" => fn["kind"],
            "results" => {}
          }
          # Prefer a top-level header for display, but keep the declaration
          # from whichever release reported it first.
          if entry["header"].to_s.include?("/internal/") && !fn["header"].to_s.include?("/internal/")
            entry["header"] = fn["header"]
          end
          result = {
            "status" => fn["status"],
            "target" => fn["target"],
            "path" => fn["path"]
          }.compact
          entry["results"][key] = result
        end
      end

      functions = by_name.values.filter_map do |entry|
        statuses = entry["results"].values.map { |r| r["status"] }
        analyzed = statuses.any? { |s| %w[no_path raises unsupported_inline].include?(s) }
        unless analyzed
          omitted += 1
          next
        end

        raise_count = statuses.count("raises")
        no_path_count = statuses.count("no_path")
        not_defined_count = statuses.count("not_defined")
        unsupported_count = statuses.count("unsupported_inline")
        missing_count = run_keys.length - entry["results"].length
        overall =
          if raise_count.positive?
            "raises_any"
          elsif no_path_count == run_keys.length
            "no_path_all"
          elsif no_path_count.positive? || unsupported_count.positive? || missing_count.positive?
            "mixed"
          else
            "other"
          end

        entry.merge(
          "overall" => overall,
          "raise_count" => raise_count,
          "no_path_count" => no_path_count,
          "missing_count" => missing_count,
          "unanalyzed_count" => missing_count + not_defined_count + unsupported_count,
          "defined" => statuses.any? { |s| s == "no_path" || s == "raises" }
        )
      end

      functions.sort_by! { |f| f["name"] }

      {
        "schema" => 1,
        "generated_at" => generated_at,
        "commit" => commit,
        "repo_url" => repo_url,
        "releases" => releases,
        "configs" => configs,
        "runs" => runs.map do |run|
          {
            "key" => run_key(run),
            "release" => run["release"],
            "config" => run["config"],
            "indirect" => run["indirect"] || "any",
            "generated_at" => run["generated_at"],
            "stats" => run["stats"],
            "escape_points" => run["escape_points"],
            "controls_ok" => run["controls_ok"],
            "controls" => run["controls"]
          }
        end,
        "summary" => {
          "runs" => runs.length,
          "functions" => functions.length,
          "omitted_not_defined" => omitted,
          "no_path_all" => functions.count { |f| f["overall"] == "no_path_all" },
          "raises_any" => functions.count { |f| f["overall"] == "raises_any" },
          "mixed" => functions.count { |f| f["overall"] == "mixed" },
          "controls_ok" => runs.all? { |run| run["controls_ok"] }
        },
        "functions" => functions
      }
    end

    def run_key(run)
      "#{run['release']}|#{run['config']}|#{run['indirect'] || 'any'}"
    end

    def h(text)
      CGI.escapeHTML(text.to_s)
    end

    def html(data)
      json = JSON.generate(data).gsub("</", "<\\/")
      release_options = data["releases"].map { |r| "<option value=\"#{h(r)}\">#{h(r)}</option>" }.join
      config_options = data["configs"].map { |c| "<option value=\"#{h(c)}\">#{h(c)}</option>" }.join
      run_count = data["runs"].length
      commit = data["commit"].to_s.empty? ? "—" : data["commit"][0, 12]
      repo = data["repo_url"].to_s
      generated = data["generated_at"].to_s

      <<~HTML
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>CRuby C API raise survey</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #f6f7f9;
            --panel: #ffffff;
            --text: #18202a;
            --muted: #5d6b7a;
            --line: #d9e0e7;
            --accent: #1664c0;
            --accent-weak: #e8f0fb;
            --ok: #126b3c;
            --ok-weak: #e4f5ea;
            --warn: #8a4b00;
            --warn-weak: #fff1d9;
            --bad: #a32626;
            --bad-weak: #fbe6e6;
            --code: #f0f3f6;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #10151b;
              --panel: #171e26;
              --text: #e6edf3;
              --muted: #9aa8b6;
              --line: #2b3743;
              --accent: #79b0ff;
              --accent-weak: #16283d;
              --ok: #7ddca6;
              --ok-weak: #12301f;
              --warn: #ffc46b;
              --warn-weak: #33230b;
              --bad: #ff9b9b;
              --bad-weak: #360f12;
              --code: #0d1217;
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            background: var(--bg);
            color: var(--text);
            font: 15px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", "Hiragino Sans", "Noto Sans JP", sans-serif;
          }
          a { color: var(--accent); }
          header.hero {
            padding: 42px 24px 28px;
            background: linear-gradient(180deg, var(--panel), var(--bg));
            border-bottom: 1px solid var(--line);
          }
          .wrap { max-width: 1180px; margin: 0 auto; }
          h1 { margin: 0 0 8px; font-size: clamp(24px, 3.5vw, 38px); letter-spacing: -0.02em; }
          h2 { margin: 0 0 12px; font-size: 20px; }
          h3 { margin: 24px 0 8px; font-size: 16px; }
          p.lead { margin: 0; color: var(--muted); max-width: 920px; }
          .meta { margin-top: 14px; color: var(--muted); font-size: 13px; display: flex; gap: 16px; flex-wrap: wrap; }
          main { padding: 26px 24px 70px; }
          .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin: 20px 0 26px; }
          .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; }
          .card .num { font-size: 26px; font-weight: 700; letter-spacing: -0.03em; }
          .card .label { color: var(--muted); font-size: 12.5px; }
          .notice { border-radius: 10px; padding: 12px 14px; margin: 14px 0; border: 1px solid var(--line); background: var(--panel); }
          .notice.warn { border-color: color-mix(in srgb, var(--warn) 40%, var(--line)); background: var(--warn-weak); }
          .notice.bad { border-color: color-mix(in srgb, var(--bad) 40%, var(--line)); background: var(--bad-weak); }
          .toolbar {
            display: grid;
            grid-template-columns: minmax(180px, 2fr) repeat(4, minmax(120px, 1fr));
            gap: 10px;
            align-items: end;
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 10px;
            padding: 14px;
            margin: 18px 0;
          }
          label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 4px; }
          input, select, button {
            font: inherit;
            color: var(--text);
            background: var(--bg);
            border: 1px solid var(--line);
            border-radius: 7px;
            padding: 8px 10px;
            min-width: 0;
          }
          input:focus, select:focus, button:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
          .table-wrap { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }
          table { width: 100%; border-collapse: collapse; font-size: 14px; }
          th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
          th { font-size: 12px; color: var(--muted); font-weight: 600; background: color-mix(in srgb, var(--panel) 70%, var(--bg)); position: sticky; top: 0; }
          tr:last-child td { border-bottom: none; }
          tbody tr:hover { background: color-mix(in srgb, var(--accent-weak) 45%, transparent); cursor: pointer; }
          code, .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.92em; }
          td.name code { font-weight: 600; }
          .header { color: var(--muted); font-size: 12px; word-break: break-all; }
          .badge { display: inline-block; border-radius: 999px; padding: 2px 8px; font-size: 12px; white-space: nowrap; border: 1px solid transparent; }
          .no_path_all { color: var(--ok); background: var(--ok-weak); border-color: color-mix(in srgb, var(--ok) 30%, transparent); }
          .raises_any { color: var(--bad); background: var(--bad-weak); border-color: color-mix(in srgb, var(--bad) 30%, transparent); }
          .mixed { color: var(--warn); background: var(--warn-weak); border-color: color-mix(in srgb, var(--warn) 30%, transparent); }
          .other { color: var(--muted); background: var(--bg); border-color: var(--line); }
          .count { color: var(--muted); font-variant-numeric: tabular-nums; }
          .pager { display: flex; gap: 10px; align-items: center; justify-content: space-between; padding: 12px 14px; color: var(--muted); font-size: 13px; }
          .pager button { padding: 6px 12px; cursor: pointer; }
          .pager button:disabled { opacity: 0.4; cursor: default; }
          .detail { margin-top: 18px; background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 18px; }
          .detail[hidden] { display: none; }
          .detail-head { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; margin-bottom: 10px; }
          .detail-head h2 { margin: 0; }
          .matrix { border: 1px solid var(--line); border-radius: 8px; overflow: auto; margin: 12px 0; }
          .matrix table { min-width: 480px; }
          .matrix th, .matrix td { padding: 8px 10px; white-space: nowrap; }
          .matrix td { font-size: 12.5px; }
          .witness { margin-top: 14px; }
          .witness li { margin: 8px 0; }
          .path { display: block; background: var(--code); border: 1px solid var(--line); border-radius: 7px; padding: 8px 10px; margin-top: 4px; overflow-wrap: anywhere; }
          .muted { color: var(--muted); }
          .method { margin-top: 34px; display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
          .method section { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 16px 18px; }
          .method ul { margin: 8px 0 0; padding-left: 1.2em; }
          .method li { margin: 4px 0; }
          footer { color: var(--muted); font-size: 12.5px; padding: 24px; border-top: 1px solid var(--line); }
          .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
          @media (max-width: 800px) {
            .toolbar { grid-template-columns: 1fr 1fr; }
            .toolbar .search { grid-column: 1 / -1; }
            th, td { padding: 8px; }
          }
        </style>
        </head>
        <body>
        <header class="hero">
          <div class="wrap">
            <h1>CRuby C API: raise する関数の調査</h1>
            <p class="lead">
              CRuby の公開 C API のうち、どの安定版でも longjmp（raise）に到達しない関数を、
              LLVM IR の呼び出しグラフから機械的に求めます。条件付きで安全な関数は含めません。
            </p>
            <div class="meta">
              <span>生成: #{h(generated)}</span>
              <span>commit: <code>#{h(commit)}</code></span>
              <span>実行: #{run_count} 組（release × config）</span>
              #{repo.empty? ? "" : "<span><a href=\"#{h(repo)}\">リポジトリ</a></span>"}
              <span><a href="data.json">data.json</a></span>
            </div>
          </div>
        </header>
        <main class="wrap">
          <div class="cards">
            <div class="card"><div class="num" id="stat-functions">—</div><div class="label">調査対象の関数</div></div>
            <div class="card"><div class="num" id="stat-no-path">—</div><div class="label">全リリースで経路なし</div></div>
            <div class="card"><div class="num" id="stat-raises">—</div><div class="label">1 版以上で raise しうる</div></div>
            <div class="card"><div class="num" id="stat-mixed">—</div><div class="label">一部の版のみ・未調査あり</div></div>
            <div class="card"><div class="num" id="stat-runs">—</div><div class="label">実行した組</div></div>
          </div>

          <div id="health"></div>

          <div class="toolbar">
            <div class="search">
              <label for="q">関数名・ヘッダで検索</label>
              <input id="q" type="search" placeholder="例: rb_str_new, rb_ary" autocomplete="off">
            </div>
            <div>
              <label for="status">判定</label>
              <select id="status">
                <option value="">すべて</option>
                <option value="no_path_all">全リリースで経路なし</option>
                <option value="raises_any">1 版以上で raise</option>
                <option value="mixed">一部の版のみ・未調査あり</option>
              </select>
            </div>
            <div>
              <label for="release">リリース</label>
              <select id="release"><option value="">すべて</option>#{release_options}</select>
            </div>
            <div>
              <label for="config">構成</label>
              <select id="config"><option value="">すべて</option>#{config_options}</select>
            </div>
            <div>
              <label for="kind">種別</label>
              <select id="kind">
                <option value="">すべて</option>
                <option value="external">external</option>
                <option value="inline">static inline</option>
              </select>
            </div>
          </div>

          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>関数</th>
                  <th>宣言ヘッダ</th>
                  <th>総合判定</th>
                  <th>raise</th>
                  <th>経路なし</th>
                  <th>未調査</th>
                </tr>
              </thead>
              <tbody id="rows"></tbody>
            </table>
            <div class="pager">
              <span id="page-info">—</span>
              <span>
                <button id="prev" type="button">前へ</button>
                <button id="next" type="button">次へ</button>
              </span>
            </div>
          </div>

          <section id="detail" class="detail" hidden>
            <div class="detail-head">
              <h2 id="detail-name"></h2>
              <span id="detail-badge"></span>
            </div>
            <div class="muted"><span id="detail-header"></span></div>
            <div class="matrix"><table><thead id="matrix-head"></thead><tbody id="matrix-body"></tbody></table></div>
            <div class="witness">
              <h3>経路の例</h3>
              <ul id="witness"></ul>
            </div>
          </section>

          <div class="method">
            <section>
              <h2>方法</h2>
              <ul>
                <li>各リリースを <code>clang -emit-llvm</code> でビルドし、<code>libruby-static.a</code> のオブジェクトから作った IR を <code>llvm-link</code> で結合する。</li>
                <li>公開 API はインストール済みヘッダの <code>FunctionDecl</code> から取る。実体のない <code>static inline</code> は、引数をそのまま渡すだけのラッパーを生成して根にする。</li>
                <li>直接呼び出し、引数として名前を渡された関数（コールバック）、間接呼び出しを辺にする。間接呼び出しは既定で「アドレスを取られた全関数を呼びうる」とみなす。</li>
                <li>脱出点は <code>longjmp</code> 系（<code>_longjmp</code>、<code>siglongjmp</code>、<code>llvm.eh.sjlj.longjmp</code> を含む）と <code>rb_ec_tag_jump</code>。</li>
              </ul>
            </section>
            <section>
              <h2>「raise しない」の意味</h2>
              <ul>
                <li>「何を渡されても raise しない」だけを安全側に数える。引数の値を区別しないため、クラスでない値のときだけ raise する関数は「raise しうる」になる。</li>
                <li>経路がないことは、そのビルドのコードについてだけ言える。拡張が登録するコールバックや <code>dlopen</code> で後から読み込まれるコードは含まない。</li>
                <li>構成（OS、configure オプション）でコードも longjmp の名前も変わる。版と構成の積集合を安全とみなす。</li>
              </ul>
            </section>
            <section>
              <h2>既知の限界</h2>
              <ul>
                <li>解析は条件分岐や引数の値を追わない。偽陽性（実際には到達しない経路）を含む。</li>
                <li>確保に伴う <code>NoMemoryError</code> はヘッダの doc コメントにほとんど書かれない。この解析はその点を補うが、外部ライブラリの中身は対象外。</li>
                <li>「raise しうる」は人が理由を確認する候補であり、<code>NON_RAISING</code> に載せるには経路の確認が必要。</li>
              </ul>
            </section>
          </div>
        </main>
        <footer class="wrap">
          <p>このページは <code>script/raise_survey/</code> の結果から生成しています。解析結果は <a href="data.json">data.json</a> から取得できます。</p>
        </footer>
        <script id="survey-data" type="application/json">#{json}</script>
        <script>
        (() => {
          const data = JSON.parse(document.getElementById('survey-data').textContent);
          const runs = data.runs;
          // Prefer the "any" indirect run for each release/config pair.
          const runByPair = {};
          for (const run of runs) {
            const pair = `${run.release}|${run.config}`;
            if (!runByPair[pair] || run.indirect === 'any') runByPair[pair] = run;
          }
          const releases = data.releases;
          const configs = data.configs;
          const statusLabel = {no_path: '経路なし', raises: 'raise しうる', not_defined: '未定義', unsupported_inline: '未解析'};
          const overallLabel = {no_path_all: '全リリースで経路なし', raises_any: 'raise しうる', mixed: '一部のみ・未調査あり', other: '未分類'};
          const overallClass = {no_path_all: 'no_path_all', raises_any: 'raises_any', mixed: 'mixed', other: 'other'};
          const state = {q: '', status: '', release: '', config: '', kind: '', page: 1, perPage: 100};
          let filtered = [];

          const $ = id => document.getElementById(id);
          const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
          const fmt = n => new Intl.NumberFormat('ja-JP').format(n ?? 0);

          function resultFor(fn, release, config) {
            const run = runByPair[`${release}|${config}`];
            return run ? fn.results[run.key] : undefined;
          }

          function statusFor(fn, release, config) {
            const r = resultFor(fn, release, config);
            return r ? r.status : 'missing';
          }

          function matches(fn) {
            if (state.kind && fn.kind !== state.kind) return false;
            if (state.status && fn.overall !== state.status) return false;
            if (state.release || state.config) {
              const rs = state.release ? [state.release] : releases;
              const cs = state.config ? [state.config] : configs;
              let seen = false;
              for (const r of rs) for (const c of cs) {
                const status = statusFor(fn, r, c);
                if (status !== 'missing' && status !== 'not_defined') seen = true;
              }
              if (!seen) return false;
            }
            if (state.q) {
              const q = state.q.toLowerCase();
              if (!fn.name.toLowerCase().includes(q) && !(fn.header || '').toLowerCase().includes(q)) return false;
            }
            return true;
          }

          function apply() {
            filtered = data.functions.filter(matches);
            state.page = 1;
            render();
          }

          function render() {
            const start = (state.page - 1) * state.perPage;
            const rows = filtered.slice(start, start + state.perPage);
            $('rows').innerHTML = rows.map(fn => {
              const raise = fn.raise_count ?? 0;
              const noPath = fn.no_path_count ?? 0;
              const unanalyzed = fn.unanalyzed_count ?? 0;
              return `<tr data-name="${esc(fn.name)}">
                <td class="name"><code>${esc(fn.name)}</code><div class="header">${fn.kind === 'inline' ? 'static inline' : ''}</div></td>
                <td class="header">${esc(fn.header || '')}</td>
                <td><span class="badge ${overallClass[fn.overall] || 'other'}">${esc(overallLabel[fn.overall] || fn.overall)}</span></td>
                <td class="count">${raise}</td>
                <td class="count">${noPath}</td>
                <td class="count">${unanalyzed || ''}</td>
              </tr>`;
            }).join('');
            const total = filtered.length;
            const pages = Math.max(1, Math.ceil(total / state.perPage));
            $('page-info').textContent = `${fmt(total)} 件中 ${total ? start + 1 : 0}–${Math.min(start + state.perPage, total)} 件（${state.page} / ${pages} ページ）`;
            $('prev').disabled = state.page <= 1;
            $('next').disabled = state.page >= pages;
            for (const tr of document.querySelectorAll('#rows tr')) {
              tr.addEventListener('click', () => showDetail(tr.dataset.name));
            }
          }

          function showDetail(name) {
            const fn = data.functions.find(f => f.name === name);
            if (!fn) return;
            $('detail').hidden = false;
            $('detail-name').textContent = fn.name;
            $('detail-badge').innerHTML = `<span class="badge ${overallClass[fn.overall] || 'other'}">${esc(overallLabel[fn.overall] || fn.overall)}</span>`;
            $('detail-header').textContent = fn.header || '';
            const head = ['<tr><th>リリース</th>' + configs.map(c => `<th>${esc(c)}</th>`).join('') + '</tr>'];
            $('matrix-head').innerHTML = head.join('');
            $('matrix-body').innerHTML = releases.map(rel => {
              const cells = configs.map(cfg => {
                const status = statusFor(fn, rel, cfg);
                if (status === 'missing') return '<td class="muted">—</td>';
                const label = statusLabel[status] || status;
                const cls = status === 'no_path' ? 'no_path_all' : status === 'raises' ? 'raises_any' : 'other';
                return `<td><span class="badge ${cls}">${esc(label)}</span></td>`;
              }).join('');
              return `<tr><th>${esc(rel)}</th>${cells}</tr>`;
            }).join('');

            const witnesses = [];
            for (const [key, result] of Object.entries(fn.results)) {
              if (result.status !== 'raises') continue;
              const [rel, cfg] = key.split('|');
              witnesses.push(`<li><code>${esc(rel)} / ${esc(cfg)}</code><span class="path">${esc((result.path || []).join(' → '))}</span></li>`);
            }
            $('witness').innerHTML = witnesses.length ? witnesses.join('') : '<li class="muted">raise に至る経路は見つかっていません。</li>';
            $('detail').scrollIntoView({behavior: 'smooth', block: 'start'});
          }

          // Summary
          const s = data.summary;
          $('stat-functions').textContent = fmt(s.functions);
          $('stat-no-path').textContent = fmt(s.no_path_all);
          $('stat-raises').textContent = fmt(s.raises_any);
          $('stat-mixed').textContent = fmt(s.mixed);
          $('stat-runs').textContent = fmt(s.runs);

          const health = [];
          if (!s.controls_ok) {
            health.push('<div class="notice bad"><strong>到達可能性の対照実験に失敗しました。</strong> raise が既知の関数が経路ありと判定されていません。解析結果を信用する前にビルドログを確認してください。</div>');
          } else {
            health.push('<div class="notice">到達可能性の対照実験: 既知の raise 関数はすべて経路ありと判定されました。</div>');
          }
          const bad = runs.filter(r => !r.controls_ok);
          if (bad.length) health.push(`<div class="notice warn">対照実験が失敗した実行: ${bad.map(r => esc(r.release + ' / ' + r.config)).join(', ')}</div>`);
          if (s.omitted_not_defined) health.push(`<div class="notice">ヘッダにあるが対象ビルドで実体が見つからない関数 ${fmt(s.omitted_not_defined)} 件は表から除外しています。</div>`);
          const controlRows = runs.map(run => {
            const items = (run.controls || []).map(c => `<code>${esc(c.name)}</code> ${c.reachable ? '✓' : '✗'}`).join(' / ');
            const escapes = (run.escape_points || []).map(e => `<code>${esc(e)}</code>`).join(', ');
            return `<li><strong>${esc(run.release)} / ${esc(run.config)}</strong>: ${items || '<span class="muted">データなし</span>'}<div class="muted">脱出点: ${escapes || '—'}</div></li>`;
          }).join('');
          health.push(`<details class="notice"><summary>対照実験と脱出点（${runs.length} 実行）</summary><ul>${controlRows}</ul></details>`);
          $('health').innerHTML = health.join('');

          // Controls in footer-ish detail
          $('q').addEventListener('input', e => { state.q = e.target.value.trim(); apply(); });
          $('status').addEventListener('change', e => { state.status = e.target.value; apply(); });
          $('release').addEventListener('change', e => { state.release = e.target.value; apply(); });
          $('config').addEventListener('change', e => { state.config = e.target.value; apply(); });
          $('kind').addEventListener('change', e => { state.kind = e.target.value; apply(); });
          $('prev').addEventListener('click', () => { if (state.page > 1) { state.page--; render(); } });
          $('next').addEventListener('click', () => { if ((state.page * state.perPage) < filtered.length) { state.page++; render(); } });

          apply();
        })();
        </script>
        </body>
        </html>
      HTML
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { inputs: ["out"], out: "site", commit: ENV["GITHUB_SHA"].to_s,
              repo_url: "", generated_at: Time.now.utc.iso8601 }
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby survey.rb --inputs DIR --out DIR"
    opts.on("--inputs LIST", "comma-separated dirs/globs") { |v| options[:inputs] = v.split(",") }
    opts.on("--out DIR", "output directory") { |v| options[:out] = v }
    opts.on("--commit SHA", "commit shown in the report") { |v| options[:commit] = v }
    opts.on("--repo-url URL", "repository link") { |v| options[:repo_url] = v }
    opts.on("--generated-at TIME", "generation time (ISO 8601)") { |v| options[:generated_at] = v }
    opts.on("-h", "--help") { puts opts; exit }
  end.parse!

  runs = RaiseSurvey::Report.load_runs(options[:inputs])
  data = RaiseSurvey::Report.build_data(
    runs,
    commit: options[:commit],
    repo_url: options[:repo_url],
    generated_at: options[:generated_at]
  )
  FileUtils.mkdir_p(options[:out])
  File.write(File.join(options[:out], "data.json"), JSON.pretty_generate(data) + "\n")
  File.write(File.join(options[:out], "index.html"), RaiseSurvey::Report.html(data))
  summary = data["summary"]
  puts "wrote #{File.join(options[:out], 'index.html')} (#{summary['functions']} functions, #{summary['runs']} runs)"
end
