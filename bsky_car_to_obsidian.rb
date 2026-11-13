#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "lib/config"
require_relative "lib/bsky_feed"
require_relative "lib/script_runner"
require_relative "extract_car"

module BskyCarToObsidian
  module_function

  def main(argv = ARGV, client: BskyFeed)
    options = { config: DEFAULT_CONFIG_PATH }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby bsky_car_to_obsidian.rb [--config PATH] [--days N | --all] [CAR_PATH]"
      opts.on("--config PATH", "Config file, default: #{DEFAULT_CONFIG_PATH}") { |value| options[:config] = value }
      opts.on("--days N", Integer, "Sync the last N calendar days, including today") do |value|
        raise OptionParser::InvalidArgument, "--days must be a positive integer" unless value.positive?

        options[:days] = value
      end
      opts.on("--all", "Write all dates, overriding obsidian.posts.days") { options[:all] = true }
    end
    parser.parse!(argv)
    raise ArgumentError, "provide at most one CAR path" if argv.size > 1
    raise ArgumentError, "--all and --days cannot be combined" if options[:all] && options[:days]

    config = load_config(options[:config])
    days = sync_days_config(config, override: options[:days])
    raise ArgumentError, "obsidian.vault_path is required" if config_get(config, "obsidian", "vault_path").to_s.strip.empty?

    directory = config_get(config, "bluesky", "out_dir", default: "out")
    car_path = argv.first || config_get(config, "bluesky", "car_path", default: "repo.car")
    did = client.resolve_actor(bluesky_actor_config(config))
    FileUtils.mkdir_p(directory)
    File.open(File.join(directory, ".bsky-sync.lock"), "a") do |lock|
      lock.flock(File::LOCK_EX)
      path = File.join(directory, "posts.jsonl")
      seed_path = File.join(directory, "records.jsonl")
      existing_path = File.file?(path) ? path : seed_path
      existing = File.file?(existing_path) ? BskyFeed.read_posts(existing_path, did) : []
      items = extract_records(Struct.new(:car_path).new(car_path), expected_did: did)
      incoming = items.map { |item| BskyFeed.normalize(item, did) }
      posts = BskyFeed.merge(existing, incoming)
      BskyFeed.write_archive(path, posts) if !File.file?(path) || posts != existing
      puts "imported CAR posts: #{incoming.size}"
      puts "archived Bluesky posts: #{posts.size}"
      args = ["--config", options[:config], "--source", "bsky"]
      args << "--all" if options[:all]
      args += ["--days", days.to_s] if days && !options[:all]
      ScriptRunner.run("upsert_obsidian_daily_notes.rb", *args)
    end
    puts "Bluesky CAR import complete"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    BskyCarToObsidian.main
  rescue StandardError => e
    warn "Bluesky CAR import failed: #{e.message}"
    exit 1
  end
end
