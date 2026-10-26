#!/usr/bin/env ruby
# frozen_string_literal: true

# api.rb -- extract the public C API from installed CRuby headers and build a
# translation unit that calls every static inline API function.
#
# Usage:
#   ruby api.rb --prefix work/install/3.4.9 --out work/api/3.4.9 [--keep-ast]
#
# Output:
#   api.json          declarations, parameter types, and wrapper names
#   survey_inline.c   one non-inline function per static inline API function
#   survey_inline.bc  compiled wrapper TU (when --clang succeeds)
#
# The wrapper functions are never executed.  They exist solely to give the
# call-graph analysis a root for functions that have no out-of-line symbol.

require "fileutils"
require "json"
require "optparse"
require "shellwords"

module RaiseSurvey
  module API
    module_function

    def find_include_dir(prefix)
      candidates = Dir.glob(File.join(prefix, "include", "ruby-*", "ruby.h")) +
                   [File.join(prefix, "include", "ruby.h")]
      header = candidates.find { |path| File.file?(path) }
      raise "ruby.h not found under #{prefix}/include" unless header

      File.dirname(header)
    end

    def find_arch_dirs(include_dir)
      dirs = Dir.glob(File.join(include_dir, "*", "ruby", "config.h")).map { |path| File.dirname(File.dirname(path)) }
      dirs += [include_dir] if File.file?(File.join(include_dir, "ruby", "config.h"))
      dirs.uniq
    end

    def umbrella_source(include_dir)
      # Include the public entry points.  ruby/internal/** is included
      # transitively by ruby.h; including every internal header explicitly
      # breaks on mutually exclusive backends (e.g. select/posix.h vs
      # select/largesize.h).  Public subdirectories such as ruby/fiber/ and
      # ruby/io/ are not all reachable from ruby.h, so include those.
      headers = Dir.glob(File.join(include_dir, "ruby", "**", "*.h")).filter_map do |path|
        relative = path.delete_prefix("#{include_dir}/")
        next if relative.include?("/internal/")
        next if relative.include?("win32")
        next if relative == "ruby/ruby.h"

        relative
      end.sort

      lines = ["#include <ruby.h>"]
      headers.each { |name| lines << "#include <#{name}>" }
      lines.join("\n") + "\n"
    end

    def normalize_header(path)
      return nil unless path

      # Source tree:   include/ruby/internal/...
      # Installed:     /prefix/include/ruby-3.4.0/ruby/internal/...
      if (match = path.match(%r{(?:\A|/)include/ruby(?:-[^/]+)?/(ruby/.+)\z}))
        match[1]
      elsif (match = path.match(%r{(?:\A|/)include/(ruby/.+)\z}))
        match[1]
      elsif path.start_with?("ruby/")
        path
      end
    end

    # clang omits "file" from loc when it is unchanged from the previous
    # printed node.  Walk the JSON in document order and remember it.
    def extract_functions(ast)
      current_file = nil
      functions = {}

      walk = lambda do |node|
        return unless node.is_a?(Hash)

        loc = node["loc"]
        if loc.is_a?(Hash)
          current_file = loc["file"] if loc["file"]
          current_file = loc.dig("expansionLoc", "file") if loc.dig("expansionLoc", "file")
          current_file = loc.dig("spellingLoc", "file") if loc.dig("spellingLoc", "file")
        end

        if node["kind"] == "FunctionDecl"
          name = node["name"].to_s
          if name.match?(/\A(?:rb_|ruby_)/)
            begin_loc = node.dig("range", "begin") || {}
            file = begin_loc.dig("expansionLoc", "file") ||
                   begin_loc.dig("spellingLoc", "file") ||
                   current_file
            header = normalize_header(file)
            if header
              inner = node["inner"] || []
              has_body = inner.any? { |child| child["kind"] == "CompoundStmt" }
              storage = node["storageClass"]
              inline = has_body && (storage == "static" || node["inline"] == true || storage.nil?)

              # static declarations without a body are the ANYARGS dispatch
              # placeholders in anyargs.h; they are never defined.
              unless storage == "static" && !has_body
                params = inner.select { |child| child["kind"] == "ParmVarDecl" }.each_with_index.map do |param, index|
                  {
                    "name" => param["name"].to_s.empty? ? "p#{index}" : param["name"],
                    "type" => param.dig("type", "qualType").to_s
                  }
                end

                qual = node.dig("type", "qualType").to_s
                variadic = node["variadic"] == true || qual.match?(/,\s*\.\.\.\)/) || qual.end_with?("(...)")

                candidate = {
                  "name" => name,
                  "header" => header,
                  "kind" => inline ? "inline" : "external",
                  "return_type" => function_return_type(qual),
                  "params" => params,
                  "variadic" => variadic
                }

                existing = functions[name]
                # Prefer an inline definition over a plain declaration, and a
                # top-level header over an internal one for display.
                if existing.nil? ||
                   (existing["kind"] == "external" && candidate["kind"] == "inline") ||
                   (existing["header"].include?("/internal/") && !candidate["header"].include?("/internal/"))
                  functions[name] = candidate
                end
              end
            end
          end
        end

        (node["inner"] || []).each { |child| walk.call(child) }
      end

      walk.call(ast)
      functions.values.sort_by { |f| f["name"] }
    end

    # "long (VALUE)" -> "long".  Function pointer returns are deliberately
    # rejected; they are not worth the complexity for the handful of APIs.
    def function_return_type(qual_type)
      return nil if qual_type.include?("(*)")

      depth = 0
      qual_type.each_char.with_index do |char, index|
        case char
        when "("
          return qual_type[0...index].strip if depth.zero?

          depth += 1
        when ")"
          depth -= 1
        end
      end
      nil
    end

    def wrapper_source(functions)
      wrappers = []
      skipped = []
      inline_functions = functions.select { |f| f["kind"] == "inline" }

      # A number of public inline functions are shadowed by function-like or
      # object-like macros after the header is processed (rb_data_object_make
      # and friends).  Undefine the names so the wrapper calls the actual
      # inline definition.
      undefs = inline_functions.map { |fn| "#undef #{fn['name']}" }

      inline_functions.each do |fn|
        if fn["variadic"]
          skipped << [fn["name"], "variadic"]
          next
        end
        ret = fn["return_type"]
        if ret.nil? || ret.empty? || ret.include?("unnamed") || ret.include?("{")
          skipped << [fn["name"], "return_type"]
          next
        end

        params = fn["params"].reject { |p| p["type"].to_s.strip == "void" }
        bad = params.find { |p| p["type"].to_s.empty? || p["type"].include?("unnamed") || p["type"].include?("{") }
        if bad
          skipped << [fn["name"], "parameter_type"]
          next
        end

        signature = params.map { |p| "#{p['type']} #{p['name']}" }.join(", ")
        args = params.map { |p| p["name"] }.join(", ")
        # Parentheses around the name prevent a function-like macro with the
        # same name (e.g. rb_data_object_wrap_warning in Ruby 3.3) from
        # expanding at the call site.
        call = "(#{fn['name']})(#{args})"
        body = ret == "void" ? "  #{call};" : "  return #{call};"
        wrappers << <<~C
          __attribute__((noinline, used))
          #{ret} survey_inline_#{fn['name']}(#{signature}) {
          #{body}
          }
        C
      end

      [(undefs + wrappers).join("\n"), skipped]
    end

    def ast_json(clang, source, include_args, out)
      cmd = [clang, "-x", "c", "-std=gnu11", "-fsyntax-only", *include_args,
             "-Xclang", "-ast-dump=json", source]
      puts "+ #{cmd.shelljoin}" if ENV["RAISE_SURVEY_VERBOSE"] == "1"
      File.open(out, "w") do |io|
        ok = system(*cmd, out: io, err: $stderr)
        raise "clang AST dump failed" unless ok
      end
    end

    def compile_wrappers(clang, source, include_args, out)
      cmd = [clang, "-x", "c", "-std=gnu11", "-O0", "-g0", "-emit-llvm", "-c",
             *include_args, "-Wno-everything", "-o", out, source]
      puts "+ #{cmd.shelljoin}" if ENV["RAISE_SURVEY_VERBOSE"] == "1"
      system(*cmd) || raise("failed to compile wrapper TU")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { keep_ast: false, clang: ENV["CCBC_REAL_CC"] || "clang", include_dirs: [], arch_dirs: [] }
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby api.rb --prefix DIR --out DIR [--include-dir DIR] [--arch-dir DIR]"
    opts.on("--prefix DIR", "install prefix (or use --include-dir/--arch-dir)") { |v| options[:prefix] = v }
    opts.on("--include-dir DIR", "header include directory (repeatable)") { |v| options[:include_dirs] << v }
    opts.on("--arch-dir DIR", "generated config.h include directory (repeatable)") { |v| options[:arch_dirs] << v }
    opts.on("--out DIR", "output directory") { |v| options[:out] = v }
    opts.on("--clang PATH", "clang executable") { |v| options[:clang] = v }
    opts.on("--keep-ast", "keep the large AST JSON") { options[:keep_ast] = true }
    opts.on("-h", "--help") { puts opts; exit }
  end.parse!

  abort "missing --out" unless options[:out]
  abort "specify --prefix or --include-dir" if options[:prefix].nil? && options[:include_dirs].empty?

  if options[:include_dirs].any?
    include_dir = File.expand_path(options[:include_dirs].first)
    arch_dirs = options[:arch_dirs].map { |dir| File.expand_path(dir) }
  else
    include_dir = RaiseSurvey::API.find_include_dir(options[:prefix])
    arch_dirs = RaiseSurvey::API.find_arch_dirs(include_dir)
  end
  raise "ruby/config.h not found under #{include_dir}" if arch_dirs.empty?
  raise "ruby.h not found in #{include_dir}" unless File.file?(File.join(include_dir, "ruby.h"))

  FileUtils.mkdir_p(options[:out])
  umbrella = File.join(options[:out], "survey_headers.c")
  File.write(umbrella, RaiseSurvey::API.umbrella_source(include_dir))

  include_args = ["-I", include_dir] + arch_dirs.flat_map { |dir| ["-I", dir] }
  ast_path = File.join(options[:out], "ast.json")
  RaiseSurvey::API.ast_json(options[:clang], umbrella, include_args, ast_path)

  ast = JSON.parse(File.read(ast_path))
  functions = RaiseSurvey::API.extract_functions(ast)
  File.delete(ast_path) unless options[:keep_ast]

  wrappers, skipped = RaiseSurvey::API.wrapper_source(functions)
  skipped_names = skipped.map(&:first).to_h { |name| [name, true] }
  functions.each do |fn|
    next unless fn["kind"] == "inline"
    next if skipped_names[fn["name"]]

    fn["wrapper"] = "survey_inline_#{fn['name']}"
  end
  wrapper_path = File.join(options[:out], "survey_inline.c")
  File.write(wrapper_path, "#{File.read(umbrella)}\n\n#{wrappers}\n")

  wrapper_bc = File.join(options[:out], "survey_inline.bc")
  RaiseSurvey::API.compile_wrappers(options[:clang], wrapper_path, include_args, wrapper_bc)

  data = {
    "schema" => 1,
    "prefix" => options[:prefix] ? File.expand_path(options[:prefix]) : nil,
    "include_dir" => include_dir,
    "arch_dirs" => arch_dirs,
    "functions" => functions,
    "wrapper_source" => wrapper_path,
    "wrapper_bc" => wrapper_bc,
    "skipped_inline" => skipped.map { |name, reason| { "name" => name, "reason" => reason } },
    "stats" => {
      "functions" => functions.length,
      "external" => functions.count { |f| f["kind"] == "external" },
      "inline" => functions.count { |f| f["kind"] == "inline" },
      "wrappers" => wrappers.scan(/__attribute__\(\(noinline, used\)\)/).length,
      "skipped_inline" => skipped.length
    }
  }
  File.write(File.join(options[:out], "api.json"), JSON.pretty_generate(data))
  puts JSON.generate(data["stats"])
end
