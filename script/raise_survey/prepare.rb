#!/usr/bin/env ruby
# frozen_string_literal: true

# prepare.rb -- print the GitHub Actions matrix for the raise survey.
#
# Usage:
#   ruby prepare.rb                     # releases.txt, linux + macos
#   ruby prepare.rb --all               # every stable release >= 3.3
#   ruby prepare.rb --releases 3.4.9,4.0.9
#   ruby prepare.rb --configs linux-x86_64:ubuntu-24.04,macos-arm64:macos-14
#
# The output is a JSON object suitable for fromJSON() in a workflow matrix:
#   {"include":[{"release":"3.4.9","config":"macos-arm64","os":"macos-14"}, ...]}

require "json"
require "optparse"
require_relative "fetch"

ROOT = File.expand_path(__dir__)
DEFAULT_CONFIGS = "linux-x86_64:ubuntu-24.04,macos-arm64:macos-14"

options = { all: false, head: false, releases: nil, configs: DEFAULT_CONFIGS,
            file: File.join(ROOT, "releases.txt") }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby prepare.rb [--all] [--head] [--releases LIST] [--configs LIST]"
  opts.on("--all", "all stable releases >= 3.3, plus HEAD") { options[:all] = true }
  opts.on("--head", "include Ruby HEAD") { options[:head] = true }
  opts.on("--releases LIST", "comma-separated versions") { |v| options[:releases] = v }
  opts.on("--configs LIST", "config:runner pairs") { |v| options[:configs] = v }
  opts.on("--file PATH", "release list file") { |v| options[:file] = v }
  opts.on("-h", "--help") { puts opts; exit }
end.parse!

versions =
  if options[:releases]
    options[:releases].split(",").map(&:strip).reject(&:empty?)
  elsif options[:all]
    RaiseSurvey::Fetch.stable_releases + ["HEAD"]
  else
    File.readlines(options[:file]).map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  end
versions << "HEAD" if options[:head]

versions = versions.uniq.sort_by do |v|
  if v.casecmp("HEAD").zero?
    [1, 0, 0, 0]
  else
    [0, *v.split(".").map(&:to_i)]
  end
end
raise "no releases selected" if versions.empty?

configs = options[:configs].split(",").map do |pair|
  config, os = pair.split(":", 2)
  raise "invalid --configs entry: #{pair}" unless config && os

  { "config" => config.strip, "os" => os.strip }
end

include_rows = versions.product(configs).map do |release, cfg|
  { "release" => release, "config" => cfg["config"], "os" => cfg["os"] }
end

puts JSON.generate({ "include" => include_rows })
