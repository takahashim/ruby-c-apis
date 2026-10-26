#!/usr/bin/env ruby
# frozen_string_literal: true

# fetch.rb -- download and extract CRuby release tarballs.
#
# Usage:
#   ruby fetch.rb --release 3.4.9 --dest work/src/3.4.9
#   ruby fetch.rb --list
#   ruby fetch.rb --list --all
#
# The release index is cache.ruby-lang.org's index.txt.  Preview and rc
# releases are deliberately ignored: the survey targets stable releases only.

require "digest"
require "fileutils"
require "optparse"
require "shellwords"

INDEX_URL = "https://cache.ruby-lang.org/pub/ruby/index.txt"

module RaiseSurvey
  module Fetch
    module_function

    def stable_version?(version)
      version.match?(/\A\d+\.\d+\.\d+\z/)
    end

    def at_least_3_3?(version)
      major, minor, = version.split(".").map(&:to_i)
      major > 3 || (major == 3 && minor >= 3)
    end

    def index_entries
      body = `curl -fsSL --retry 3 --retry-delay 2 #{INDEX_URL.shellescape}`
      raise "failed to fetch #{INDEX_URL}" unless $?.success?

      entries = {}
      body.each_line.drop(1).each do |line|
        name, url, _sha1, sha256 = line.chomp.split("\t")
        next unless name && url && sha256

        version = name.delete_prefix("ruby-")
        next unless stable_version?(version)
        next unless url.end_with?(".tar.gz")

        # index.txt lists tar.gz, tar.xz and zip; keep the first (tar.gz).
        entries[version] ||= { url: url, sha256: sha256 }
      end
      entries
    end

    def stable_releases(all: false)
      entries = index_entries
      versions = entries.keys.select { |v| all || at_least_3_3?(v) }
      versions.sort_by { |v| v.split(".").map(&:to_i) }
    end

    def download(version, dest, cache: nil)
      entries = index_entries
      entry = entries.fetch(version) do
        raise "unknown stable release: #{version} (see --list)"
      end

      FileUtils.mkdir_p(dest)
      parent = File.dirname(dest)
      FileUtils.mkdir_p(parent)
      tarball = cache ? File.join(cache, "ruby-#{version}.tar.gz") : "#{dest}.tar.gz"
      FileUtils.mkdir_p(File.dirname(tarball)) unless File.exist?(File.dirname(tarball))

      unless File.exist?(tarball) && Digest::SHA256.file(tarball).hexdigest == entry[:sha256]
        FileUtils.rm_f(tarball)
        system("curl", "-fSL", "--retry", "3", "--retry-delay", "2", "-o", tarball, entry[:url]) ||
          raise("failed to download #{entry[:url]}")
        actual = Digest::SHA256.file(tarball).hexdigest
        raise "sha256 mismatch for #{tarball}: #{actual}" unless actual == entry[:sha256]
      end

      source = File.join(dest, "ruby-#{version}")
      return source if File.directory?(source) && File.exist?(File.join(source, "configure"))

      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      system("tar", "xzf", tarball, "-C", dest) || raise("failed to extract #{tarball}")
      raise "unexpected archive layout: #{source}" unless File.directory?(source)

      source
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { all: false, list: false, dest: nil, release: nil, cache: nil }
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby fetch.rb --release VERSION --dest DIR"
    opts.on("--release VERSION", "e.g. 3.4.9") { |v| options[:release] = v }
    opts.on("--dest DIR", "extraction directory") { |v| options[:dest] = v }
    opts.on("--cache DIR", "tarball cache") { |v| options[:cache] = v }
    opts.on("--list", "list releases") { options[:list] = true }
    opts.on("--all", "include releases older than 3.3") { options[:all] = true }
    opts.on("-h", "--help") { puts opts; exit }
  end.parse!

  if options[:list]
    puts RaiseSurvey::Fetch.stable_releases(all: options[:all])
  elsif options[:release] && options[:dest]
    puts RaiseSurvey::Fetch.download(options[:release], options[:dest], cache: options[:cache])
  else
    warn "specify --release and --dest, or --list"
    exit 2
  end
end
