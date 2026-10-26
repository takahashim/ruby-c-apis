#!/usr/bin/env ruby
# frozen_string_literal: true

# ccbc.rb -- clang wrapper that emits LLVM bitcode next to every object file.
#
# Configure CRuby with CC=/path/to/ccbc.rb.  The wrapper runs the real
# compiler exactly as usual, and additionally compiles every C/C++ source with
# -emit-llvm into a sidecar .bc file.  Failures of the sidecar compile are
# recorded in CCBC_LOG and do not break the real build.
#
# Environment:
#   CCBC_REAL_CC  real compiler (default: clang)
#   CCBC_LOG      path to a log file for skipped/failed sidecar compiles
#   CCBC_VERBOSE  set to 1 to print sidecar compiles

require "shellwords"

real_cc = ENV.fetch("CCBC_REAL_CC", "clang")
log_path = ENV["CCBC_LOG"]
verbose = ENV["CCBC_VERBOSE"] == "1"

def log(path, message)
  return unless path

  File.open(path, "a") { |f| f.puts(message) }
end

source = ARGV.find { |arg| arg =~ /\.(?:c|cc|cpp|cxx|m|mm)\z/ }
compile_only = ARGV.include?("-c")
output_index = ARGV.index("-o")
output = output_index && ARGV[output_index + 1]

if source && compile_only && output && output.end_with?(".o")
  bc = output.sub(/\.o\z/, ".bc")
  # Do not let a stale sidecar mask a failed compile.
  File.delete(bc) if File.exist?(bc)

  # Strip flags which only make sense for the final object / assembler
  # invocation.  Keeping them is mostly harmless, but -Wa, -Wp and dependency
  # flags can make -emit-llvm fail on some versions of clang.
  args = []
  skip_next = false
  ARGV.each do |arg|
    if skip_next
      skip_next = false
      next
    end
    case arg
    when "-o", "-MF", "-MT", "-MQ"
      skip_next = true
      next
    when /\A-Wa,/, /\A-Wp,/, "-MMD", "-MD", "-MP"
      next
    else
      args << arg
    end
  end
  args << "-emit-llvm"
  args << "-o" << bc

  unless system(real_cc, *args)
    File.delete(bc) if File.exist?(bc)
    log(log_path, "bitcode_failed\t#{source}")
    warn "ccbc: could not emit bitcode for #{source}" if verbose
  end
end

exec real_cc, *ARGV
