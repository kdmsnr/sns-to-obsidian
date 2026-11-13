#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/config"
require_relative "lib/script_runner"
require_relative "lib/x_archive"
require_relative "lib/x_feed"

module XArchiveToObsidian
  module_function

  def required_config(config, *keys)
    value = config_get(config, *keys).to_s.strip
    raise ArgumentError, "#{keys.join('.')} is required" if value.empty?

    value
  end

  def main(argv = ARGV)
    options = { config: DEFAULT_CONFIG_PATH }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby x_archive_to_obsidian.rb [--config PATH] [--days N | --all] ARCHIVE"
      opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") { |value| options[:config] = value }
      opts.on("--days N", Integer, "Sync the last N calendar days, including today") do |value|
        raise OptionParser::InvalidArgument, "--days must be a positive integer" unless value.positive?

        options[:days] = value
      end
      opts.on("--all", "Write all dates, overriding obsidian.posts.days") { options[:all] = true }
    end
    parser.parse!(argv)
    raise ArgumentError, "provide exactly one archive path" unless argv.size == 1
    raise ArgumentError, "--all and --days cannot be combined" if options[:all] && options[:days]

    config = load_config(options[:config])
    days = sync_days_config(config, override: options[:days])
    required_config(config, "obsidian", "vault_path")
    handle = required_config(config, "x", "handle")
    directory = config_get(config, "x", "archive_dir", default: "x-archive")
    posts = XFeed.merge_posts(XArchive.parse(argv.first, handle: handle), directory)
    puts "archived X posts: #{posts.size}"

    args = ["--config", options[:config], "--source", "x"]
    args << "--all" if options[:all]
    args += ["--days", days.to_s] if days && !options[:all]
    ScriptRunner.run("upsert_obsidian_daily_notes.rb", *args)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    XArchiveToObsidian.main
  rescue StandardError => e
    warn "X archive import failed: #{e.message}"
    exit 1
  end
end
