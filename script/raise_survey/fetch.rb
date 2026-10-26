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

    def head?(version)
      version.to_s.casecmp("HEAD").zero?
    end

    def head_sha
      output = `git ls-remote https://github.com/ruby/ruby.git refs/heads/master 2>/dev/null`
      return nil unless $?.success?

      output.split.first
    end

    # HEAD is a moving target.  Pin the archive to the current commit SHA so
    # that the build metadata and the published result refer to a specific
    # revision, while the report label stays "HEAD".
    def download_head(dest, cache: nil)
      sha = head_sha
      label = sha || "master"
      source = File.join(dest, "ruby-head")
      stamp = File.join(source, ".raise_survey_head_sha")

      if File.directory?(source) && File.exist?(File.join(source, "configure")) &&
         File.exist?(stamp) && File.read(stamp).strip == label
        return source
      end

      FileUtils.mkdir_p(File.dirname(dest))
      tarball = cache ? File.join(cache, "ruby-head-#{label}.tar.gz") : "#{dest}.tar.gz"
      FileUtils.mkdir_p(File.dirname(tarball))
      # Keep only the tarball for the current HEAD; otherwise the CI cache
      # grows by one archive every run.
      Dir.glob(File.join(File.dirname(tarball), "ruby-head-*.tar.gz")).each do |old|
        FileUtils.rm_f(old) unless File.expand_path(old) == File.expand_path(tarball)
      end
      unless File.exist?(tarball)
        url = "https://github.com/ruby/ruby/archive/#{label}.tar.gz"
        system("curl", "-fSL", "--retry", "3", "--retry-delay", "2", "-o", tarball, url) ||
          raise("failed to download #{url}")
      end

      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      system("tar", "xzf", tarball, "-C", dest) || raise("failed to extract #{tarball}")
      extracted = Dir.glob(File.join(dest, "ruby-*")).find { |path| File.directory?(path) }
      raise "unexpected HEAD archive layout under #{dest}" unless extracted

      FileUtils.mv(extracted, source)
      File.write(stamp, "#{label}\n")

      # The git checkout has configure.ac but no generated configure.
      # autoreconf (via autogen.sh) needs autoconf/automake/libtool, and later
      # make needs bison for parse.y.
      generated =
        Dir.chdir(source) do
          system("sh", "autogen.sh") || system("autoreconf", "--install")
        end
      raise "failed to generate configure for HEAD" unless generated
      raise "configure was not generated for HEAD" unless File.file?(File.join(source, "configure"))

      File.chmod(0o755, File.join(source, "configure"))
      source
    end

    def download(version, dest, cache: nil)
      return download_head(dest, cache: cache) if head?(version)

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
