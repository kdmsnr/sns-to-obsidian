#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

require_relative "lib/config"
require_relative "lib/bsky_feed"
require_relative "lib/script_runner"

module BskyToObsidian
  module_function

  def parse_options(argv)
    options = { config: DEFAULT_CONFIG_PATH }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby bsky_to_obsidian.rb [--config PATH] [--days N] [--offline]"
      opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") { |value| options[:config] = value }
      opts.on("--days N", Integer, "Sync the last N calendar days, including today") do |value|
        raise OptionParser::InvalidArgument, "--days must be a positive integer" unless value.positive?

        options[:days] = value
      end
      opts.on("--offline", "Write notes from saved posts without network access") { options[:offline] = true }
    end
    parser.parse!(argv)
    raise ArgumentError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

    options
  end

  def run_command(script, *args)
    ScriptRunner.run(script, *args)
  end

  def sync(config, options, client: BskyFeed)
    directory = config_get(config, "bluesky", "archive_dir", default: "out")
    path = File.join(directory, "posts.jsonl")
    seed_path = File.join(directory, "records.jsonl")
    did = client.resolve_actor(bluesky_actor_config(config))
    existing = File.file?(path) ? BskyFeed.read_posts(path, did) : []
    seed = !File.file?(path) && File.file?(seed_path) ? BskyFeed.read_posts(seed_path, did) : []
    history = BskyFeed.merge(existing, seed)
    incoming = client.fetch_latest(did, known_uris: history.map { |post| post.fetch("uri") })
    posts = BskyFeed.merge(history, incoming)
    # Do not commit a partial API fetch. Retrying also replays note updates if writing failed.
    BskyFeed.write_archive(path, posts) if !File.file?(path) || posts != existing
    puts "fetched Bluesky posts: #{incoming.size}"
    puts "archived Bluesky posts: #{posts.size}"
  end

  def main(argv = ARGV, client: BskyFeed)
    options = parse_options(argv)
    config = load_config(options.fetch(:config))
    days = sync_days_config(config, override: options[:days])
    if config_get(config, "obsidian", "vault_path").to_s.strip.empty?
      raise ArgumentError, "obsidian.vault_path is required"
    end

    directory = config_get(config, "bluesky", "archive_dir", default: "out")
    FileUtils.mkdir_p(directory)
    File.open(File.join(directory, ".bsky-sync.lock"), "a") do |lock|
      lock.flock(File::LOCK_EX)
      sync(config, options, client: client) unless options[:offline]
      args = ["--config", options.fetch(:config), "--source", "bsky"]
      args += ["--days", days.to_s] if days
      run_command("upsert_obsidian_daily_notes.rb", *args)
    end
    puts "bsky to obsidian complete"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    BskyToObsidian.main
  rescue StandardError => e
    warn "Bluesky import failed: #{e.message}"
    exit 1
  end
end
