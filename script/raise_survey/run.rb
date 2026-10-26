#!/usr/bin/env ruby
# frozen_string_literal: true

# run.rb -- one release, one configuration, end to end.
#
# Usage:
#   ruby run.rb --release 3.4.9 --work work --out out [--jobs 8] \
#               [--indirect any|typed] [--config macos-arm64]
#
# The steps are intentionally separate commands so that a failed build leaves
# enough intermediate state behind for debugging:
#
#   fetch.rb -> build.rb -> api.rb -> analyze.py
#
# Work layout:
#   work/<release>/src       extracted source
#   work/<release>/build     build tree (contains raise_survey/all.ll)
#   work/<release>/install   install prefix
#   work/<release>/api       api.json + survey_inline.{c,bc}
#   out/<release>-<config>.json

require "fileutils"
require "json"
require "optparse"
require "rbconfig"
require "shellwords"
require "time"

ROOT = File.expand_path(__dir__)
require_relative "fetch"
require_relative "build"

module RaiseSurvey
  module Run
    module_function

    def script(name)
      File.join(ROOT, name)
    end

    def ruby(*args)
      system(RbConfig.ruby, *args) || raise("ruby #{args.shelljoin} failed")
    end

    def python(*args)
      python = ENV.fetch("PYTHON", "python3")
      system(python, *args) || raise("#{python} #{args.shelljoin} failed")
    end

    def commit
      return ENV["GITHUB_SHA"] if ENV["GITHUB_SHA"] && !ENV["GITHUB_SHA"].empty?

      value = `git rev-parse HEAD 2>/dev/null`.strip
      value.empty? ? "" : value
    end

    def release_url(release)
      "https://github.com/ruby/ruby/tree/v#{release.gsub('.', '_')}"
    end

    def run(release:, work:, out:, jobs:, indirect:, config: nil, skip_fetch: false,
            skip_build: false, skip_api: false, skip_analyze: false)
      config ||= Build.host_config
      base = File.join(work, release)
      src = File.join(base, "src", "ruby-#{release}")
      build_dir = File.join(base, "build")
      prefix = File.join(base, "install")
      api_dir = File.join(base, "api")
      FileUtils.mkdir_p(File.join(work, "cache"))

      unless skip_fetch
        puts "== fetch ruby #{release}"
        src = Fetch.download(release, File.dirname(src), cache: File.join(work, "cache"))
      end

      unless skip_build
        puts "== build ruby #{release} (#{config})"
        Build.configure(src: src, build: build_dir, prefix: prefix, jobs: jobs)
      end

      meta = {}
      meta["config"] = config
      meta["compiler"] = Build.clang_version(ENV["CCBC_REAL_CC"] || "clang")

      unless skip_api
        puts "== extract public API"
        include_dir = File.join(src, "include")
        arch_dirs = Dir.glob(File.join(build_dir, ".ext", "include", "*", "ruby", "config.h"))
                       .map { |path| File.dirname(File.dirname(path)) }
        raise "ruby/config.h not found under #{build_dir}/.ext/include" if arch_dirs.empty?

        args = ["--include-dir", include_dir, "--out", api_dir]
        arch_dirs.each { |dir| args.concat(["--arch-dir", dir]) }
        ruby(script("api.rb"), *args)
      end

      unless skip_analyze
        puts "== link bitcode"
        bc_files, missing = Build.core_bitcode(build_dir)
        warn "warning: #{missing.length} archive members have no bitcode" unless missing.empty?
        wrapper_bc = File.join(api_dir, "survey_inline.bc")
        extra = File.file?(wrapper_bc) ? [wrapper_bc] : []
        link_meta = Build.link_bitcode(build_dir, bc_files, extra_bc: extra)
        meta.merge!(link_meta)
        meta["missing_bitcode"] = missing
        meta["selected_bitcode"] = bc_files.length

        puts "== analyze call graph (#{indirect})"
        out_path = File.join(out, "#{release}-#{config}.json")
        FileUtils.mkdir_p(out)
        python(script("analyze.py"), "--ir", link_meta["all_ll"],
               "--api", File.join(api_dir, "api.json"),
               "--release", release, "--config", config, "--indirect", indirect,
               "--out", out_path, "--commit", commit, "--source-url", release_url(release))

        # Attach the build metadata after analyze.py has written the file, so
        # the report can show what was actually compiled.
        data = JSON.parse(File.read(out_path))
        data["build"] = meta
        data["build"]["built_at"] = Time.now.utc.iso8601
        File.write(out_path, JSON.pretty_generate(data) + "\n")
        puts "== wrote #{out_path}"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { work: "work", out: "out", jobs: 8, indirect: "any" }
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby run.rb --release VERSION --work DIR --out DIR"
    opts.on("--release VERSION", "CRuby version, e.g. 3.4.9") { |v| options[:release] = v }
    opts.on("--work DIR", "work directory") { |v| options[:work] = v }
    opts.on("--out DIR", "JSON output directory") { |v| options[:out] = v }
    opts.on("--jobs N", Integer, "parallel build jobs") { |v| options[:jobs] = v }
    opts.on("--indirect MODE", %w[any typed], "indirect call model") { |v| options[:indirect] = v }
    opts.on("--config NAME", "configuration label") { |v| options[:config] = v }
    opts.on("--skip-fetch", "reuse the extracted source") { options[:skip_fetch] = true }
    opts.on("--skip-build", "reuse the build tree and install") { options[:skip_build] = true }
    opts.on("--skip-api", "reuse api.json and wrapper bitcode") { options[:skip_api] = true }
    opts.on("--skip-analyze", "stop after building") { options[:skip_analyze] = true }
    opts.on("-h", "--help") { puts opts; exit }
  end.parse!

  abort "missing --release" unless options[:release]

  RaiseSurvey::Run.run(
    release: options[:release],
    work: options[:work],
    out: options[:out],
    jobs: options[:jobs],
    indirect: options[:indirect],
    config: options[:config],
    skip_fetch: options[:skip_fetch],
    skip_build: options[:skip_build],
    skip_api: options[:skip_api],
    skip_analyze: options[:skip_analyze]
  )
end
