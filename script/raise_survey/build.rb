#!/usr/bin/env ruby
# frozen_string_literal: true

# build.rb -- build CRuby with clang's bitcode sidecars and link the bitcode.
#
# Usage:
#   ruby build.rb --src work/src/ruby-3.4.9 --build work/build/3.4.9 \
#                 --prefix work/install/3.4.9 [--jobs 8]
#
# The result is work/build/3.4.9/raise_survey/all.ll (plus all.bc and
# build_meta.json).  The configured compiler is ccbc.rb, which writes a .bc
# next to each .o.  Core objects are selected from libruby-static.a; extension
# objects are not part of the C API and are ignored.

require "fileutils"
require "json"
require "optparse"
require "rbconfig"
require "set"
require "shellwords"
require "time"

module RaiseSurvey
  module Build
    module_function

    ROOT = File.expand_path(__dir__)
    CCBC = File.join(ROOT, "ccbc.rb")

    def which(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.executable?(path)
      end
      nil
    end

    def versioned_tool(name)
      which(name) || Dir.glob(File.expand_path("~/.rustup/toolchains/*/lib/rustlib/*/bin/#{name}")).first ||
        Dir.glob("/usr/lib/llvm-*/bin/#{name}").sort.last ||
        Dir.glob("/opt/homebrew/opt/llvm/bin/#{name}").first
    end

    def host_config
      os = RbConfig::CONFIG["host_os"]
      cpu = RbConfig::CONFIG["host_cpu"]
      os = "macos" if os.include?("darwin")
      os = "linux" if os.include?("linux")
      cpu = "arm64" if %w[aarch64 arm64].include?(cpu)
      cpu = "x86_64" if %w[x86_64 amd64].include?(cpu)
      "#{os}-#{cpu}"
    end

    def run!(env, *cmd, chdir: nil)
      printable = cmd.map { |part| part.to_s.include?(" ") ? part.inspect : part }.join(" ")
      puts "+ #{printable}" if ENV["RAISE_SURVEY_VERBOSE"] != "0"
      ok = chdir ? system(env, *cmd, chdir: chdir) : system(env, *cmd)
      raise "command failed: #{printable}" unless ok
    end

    # Expand a simple make variable.  Ruby's Makefile uses
    # LIBRUBY_A = lib$(RUBY_SO_NAME)-static.a, and RUBY_SO_NAME differs
    # between platforms (libruby.3.4-static.a on macOS, libruby-static.a on
    # Linux with --disable-shared).
    def make_var(makefile, name, depth = 0)
      return nil if depth > 10

      raw = makefile[/^#{Regexp.escape(name)}\s*=\s*(.*)$/, 1]
      return nil unless raw

      raw.gsub(/\$[({]([A-Za-z0-9_]+)[)}]/) do
        make_var(makefile, Regexp.last_match(1), depth + 1) || ""
      end.strip
    end

    def configure(src:, build:, prefix:, jobs:)
      src = File.expand_path(src)
      build = File.expand_path(build)
      prefix = File.expand_path(prefix)
      FileUtils.mkdir_p(build)
      FileUtils.mkdir_p(prefix)

      real_cc = ENV["CCBC_REAL_CC"] || which("clang") || raise("clang not found")
      File.chmod(0o755, CCBC)
      cc = "#{RbConfig.ruby} #{CCBC}"

      env = {
        "CC" => cc,
        "CXX" => cc,
        "CCBC_REAL_CC" => real_cc,
        "CCBC_LOG" => File.join(build, "ccbc.log"),
        "CCBC_VERBOSE" => "0",
        # Keep the call graph close to the source: -O0 preserves call sites and
        # avoids inlining away transitions that the analysis needs to see.
        "optflags" => "-O0 -g0",
        "debugflags" => ""
      }

      configure_args = [
        File.join(src, "configure"),
        "--prefix=#{prefix}",
        "--disable-install-doc",
        "--disable-shared",
        "--disable-yjit",
        "--without-gmp"
      ]
      # Ruby 4.0 ships ZJIT (Rust).  It is not needed for the C API survey and
      # makes the build depend on a matching Rust toolchain.
      major = File.basename(src)[/^ruby-(\d+)\./, 1].to_i
      configure_args << "--disable-zjit" if major >= 4

      extra = ENV.fetch("RAISE_SURVEY_CONFIGURE_ARGS", "").split
      configure_args.concat(extra)
      run!(env, *configure_args, chdir: build)

      jobs = jobs.to_i
      jobs = 8 if jobs <= 0

      # Build the interpreter and the static core library only.  A full
      # `make` also builds extensions and gems, which are irrelevant to the C
      # API survey and frequently fail for unrelated reasons (OpenSSL,
      # missing optional headers, ...).  Headers come from the source tree and
      # the generated config.h, so `make install` is unnecessary.
      run!(env, "make", "-j#{jobs}", "miniruby", chdir: build)

      makefile = File.read(File.join(build, "Makefile"))
      target = make_var(makefile, "LIBRUBY_A") || "libruby-static.a"
      run!(env, "make", "-j#{jobs}", target, chdir: build)
    end

    def core_bitcode(build)
      archive = Dir.glob(File.join(build, "libruby*-static.a")).first
      raise "libruby*-static.a not found in #{build}" unless archive && File.file?(archive)

      members = `ar t #{archive.shellescape}`.lines.map(&:strip)
      members.reject! { |member| member.empty? || member == "__.SYMDEF SORTED" || member == "__.SYMDEF" }
      raise "could not read members of #{archive}" unless $?.success?

      # `ar t` only shows basenames, and Ruby's archive intentionally contains
      # duplicate names (encoding.o, node.o, pack.o from both the core and
      # Prism).  A member name can therefore correspond to more than one .bc;
      # include all of them.  Objects that are only used for linking miniruby
      # (main.o, miniinit.o, dmydln.o) are not archive members and are excluded.
      by_basename = Hash.new { |h, k| h[k] = [] }
      Dir.glob(File.join(build, "**", "*.bc")).each do |path|
        next if path.include?("/ext/") || path.include?("/install/") ||
                path.include?("/.ext/") || path.include?("/target/") ||
                path.include?("/raise_survey/")

        by_basename[File.basename(path, ".bc") + ".o"] << path
      end

      selected = []
      missing = []
      members.uniq.each do |member|
        candidates = by_basename[File.basename(member)]
        if candidates.empty?
          missing << member
        else
          selected.concat(candidates)
        end
      end

      [selected.uniq.sort, missing]
    end

    def link_bitcode(build, bc_files, extra_bc: [])
      llvm_link = versioned_tool("llvm-link") || raise("llvm-link not found")
      llvm_dis = versioned_tool("llvm-dis") || raise("llvm-dis not found")
      outdir = File.join(build, "raise_survey")
      FileUtils.mkdir_p(outdir)
      all_bc = File.join(outdir, "all.bc")
      all_ll = File.join(outdir, "all.ll")

      inputs = (bc_files + extra_bc).uniq
      raise "no bitcode files to link" if inputs.empty?

      run!({}, llvm_link, "-o", all_bc, *inputs)
      run!({}, llvm_dis, all_bc, "-o", all_ll)

      {
        "all_bc" => all_bc,
        "all_ll" => all_ll,
        "input_count" => inputs.length,
        "all_ll_bytes" => File.size(all_ll)
      }
    end

    def clang_version(clang)
      `#{clang.shellescape} --version 2>&1`.lines.first.to_s.strip
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { jobs: 8 }
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby build.rb --src DIR --build DIR --prefix DIR"
    opts.on("--src DIR", "CRuby source tree") { |v| options[:src] = v }
    opts.on("--build DIR", "build directory") { |v| options[:build] = v }
    opts.on("--prefix DIR", "install prefix") { |v| options[:prefix] = v }
    opts.on("--jobs N", Integer, "parallel build jobs") { |v| options[:jobs] = v }
    opts.on("-h", "--help") { puts opts; exit }
  end.parse!

  abort "missing --src" unless options[:src]
  abort "missing --build" unless options[:build]
  abort "missing --prefix" unless options[:prefix]

  RaiseSurvey::Build.configure(**options)
  bc_files, missing = RaiseSurvey::Build.core_bitcode(options[:build])
  warn "warning: #{missing.length} archive members have no bitcode" unless missing.empty?

  meta = RaiseSurvey::Build.link_bitcode(options[:build], bc_files)
  meta.merge!(
    "config" => RaiseSurvey::Build.host_config,
    "compiler" => RaiseSurvey::Build.clang_version(ENV["CCBC_REAL_CC"] || "clang"),
    "jobs" => options[:jobs],
    "missing_bitcode" => missing,
    "selected_bitcode" => bc_files.length,
    "built_at" => Time.now.utc.iso8601
  )
  File.write(File.join(options[:build], "raise_survey", "build_meta.json"), JSON.pretty_generate(meta))
  puts JSON.generate(meta)
end
