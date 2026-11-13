#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "date"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"
require "fileutils"
require "yaml"

require_relative "../lib/x_archive"
require_relative "../lib/x_feed"

def assert_equal(expected, actual, message)
  return if expected == actual

  raise "#{message}: expected #{expected.inspect}, got #{actual.inspect}"
end

def assert_raises(message)
  begin
    yield
  rescue StandardError
    return
  end
  raise "#{message}: expected an error"
end

def write_tweets(path, tweets, assignment: "window.YTD.tweets.part0")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#{assignment} = #{JSON.generate(tweets.map { |tweet| { 'tweet' => tweet } })};\n", encoding: "UTF-8")
end

def tweet(id, text:, date: "Sat Sep 19 15:05:00 +0000 2026", urls: [])
  { "id_str" => id, "created_at" => date, "full_text" => text, "entities" => { "urls" => urls } }
end

def run_script(*args)
  Open3.capture3(RbConfig.ruby, File.expand_path("../x_archive_to_obsidian.rb", __dir__), *args)
end

Dir.mktmpdir("x-official-archive-test") do |directory|
  archive = File.join(directory, "export")
  first_file = File.join(archive, "data", "tweets.js")
  second_file = File.join(archive, "data", "tweets-part1.js")
  url = { "url" => "https://t.co/abcdef", "expanded_url" => "https://example.com/日本語" }
  first = tweet("100", text: "日本語の投稿\nリンク https://t.co/abcdef", urls: [url])
  second = tweet("101", text: "次の投稿", date: "Sat Sep 19 15:10:00 +0000 2026")
  repost = tweet("102", text: "RT @other: リポスト")
  write_tweets(first_file, [first, repost])
  write_tweets(second_file, [second], assignment: "window.YTD.tweets.part1")

  posts = XArchive.parse(archive, handle: "self")
  assert_equal(%w[100 101], posts.map { |post| post.fetch("id") }.sort, "all archive parts are read and reposts are excluded")
  post = posts.find { |item| item.fetch("id") == "100" }
  assert_equal("self", post.fetch("author"), "the configured handle identifies archive posts")
  assert_equal("2026-09-19T15:05:00Z", post.fetch("created_at"), "archive dates are normalized to UTC")
  assert_equal("日本語の投稿\nリンク https://example.com/日本語", post.fetch("text"), "Unicode, line breaks, and expanded URLs survive")
  assert_equal("https://x.com/self/status/100", post.fetch("url"), "the canonical status link is generated")
  assert_equal(["100"], XArchive.parse(first_file, handle: "self").map { |item| item.fetch("id") }, "a single JS file can be imported")

  zip_directory = File.join(directory, "downloads")
  FileUtils.mkdir_p(zip_directory)
  zip_path = File.join(zip_directory, "twitter-archive.zip")
  _stdout, stderr, status = Open3.capture3("zip", "-q", "-r", zip_path, "data", chdir: archive)
  raise "could not create a ZIP fixture: #{stderr}" unless status.success?

  assert_equal(posts, XArchive.parse(zip_path, handle: "self"), "a ZIP archive can be imported directly")
  assert_equal(posts, XArchive.parse(zip_directory, handle: "self"), "a directory containing the ZIP can be imported")

  legacy_file = File.join(directory, "legacy", "data", "tweet.js")
  write_tweets(legacy_file, [second], assignment: "window.YTD.tweet.part0")
  assert_equal(["101"], XArchive.parse(File.dirname(File.dirname(legacy_file)), handle: "self").map { |item| item.fetch("id") }, "the old tweet.js name is supported")
  empty_file = File.join(directory, "empty.js")
  write_tweets(empty_file, [])
  assert_equal([], XArchive.parse(empty_file, handle: "self"), "an empty official archive is valid")

  vault = File.join(directory, "vault")
  history = File.join(directory, "history")
  FileUtils.mkdir_p(history)
  old = { "id" => "100", "author" => "self", "url" => "https://x.com/self/status/100", "created_at" => "2026-09-19T15:05:00Z", "text" => "RSS old copy" }
  retained = { "id" => "99", "author" => "self", "url" => "https://x.com/self/status/99", "created_at" => "2026-09-19T15:00:00Z", "text" => "RSS only" }
  File.write(File.join(history, "posts.jsonl"), [old, retained].map { |record| JSON.generate(record) }.join("\n") + "\n")
  config = { "x" => { "handle" => "self", "archive_dir" => history }, "obsidian" => { "vault_path" => vault, "timezone" => "Asia/Tokyo" } }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  note_path = File.join(vault, "Daily", "2026-09-20.md")
  FileUtils.mkdir_p(File.dirname(note_path))
  File.write(note_path, "# 手書き\n\nメモ\n")

  _stdout, stderr, status = run_script("--config", config_path, zip_directory)
  assert_equal(true, status.success?, "archive CLI succeeds: #{stderr}")
  saved = XFeed.read_archive(history)
  assert_equal(%w[100 101 99], saved.map { |item| item.fetch("id") }.sort, "official and RSS histories merge by ID")
  assert_equal(post.fetch("text"), saved.find { |item| item.fetch("id") == "100" }.fetch("text"), "incoming archive updates a matching RSS post")
  note = File.read(note_path)
  assert_equal(true, note.include?("# 手書き") && note.include?("メモ"), "handwritten note content remains")
  assert_equal(true, note.include?("`00:05` [X](https://x.com/self/status/100)\n日本語の投稿\nリンク https://example.com/日本語"), "the imported post is written in local time")
  assert_equal(true, note.include?("RSS only") && note.include?("次の投稿"), "old and new posts are written")
  assert_equal(false, note.include?("リポスト"), "reposts are not written")
  history_before = File.binread(File.join(history, "posts.jsonl"))
  _stdout, stderr, status = run_script("--config", config_path, archive)
  assert_equal(true, status.success?, "repeat import succeeds: #{stderr}")
  assert_equal(note, File.read(note_path), "repeat import leaves notes unchanged")
  assert_equal(history_before, File.binread(File.join(history, "posts.jsonl")), "repeat import leaves history unchanged")

  bad_file = File.join(archive, "data", "tweets-part1.js")
  File.write(bad_file, "window.YTD.tweets.part1 = [{ invalid }];")
  _stdout, _stderr, status = run_script("--config", config_path, archive)
  assert_equal(false, status.success?, "a malformed part makes the import fail")
  assert_equal(history_before, File.binread(File.join(history, "posts.jsonl")), "failed import leaves history untouched")
  assert_equal(note, File.read(note_path), "failed import leaves notes untouched")
  assert_raises("a missing archive fails") { XArchive.parse(File.join(directory, "missing"), handle: "self") }
  bad_data = File.join(directory, "invalid.js")
  write_tweets(bad_data, [tweet("bad", text: "bad", date: "invalid")])
  assert_raises("an invalid date fails") { XArchive.parse(bad_data, handle: "self") }
  write_tweets(bad_data, [tweet("", text: "bad")])
  assert_raises("a missing ID fails") { XArchive.parse(bad_data, handle: "self") }

  [["--config", config_path], ["--config", config_path, first_file, first_file]].each do |args|
    _stdout, _stderr, status = run_script(*args)
    assert_equal(false, status.success?, "missing or extra archive paths are rejected")
    assert_equal(history_before, File.binread(File.join(history, "posts.jsonl")), "invalid arguments do not change history")
    assert_equal(note, File.read(note_path), "invalid arguments do not change notes")
  end
end

Dir.mktmpdir("x-archive-all-test") do |directory|
  today = Time.now.getlocal("+09:00").to_date
  old_day = today - 30
  archive_file = File.join(directory, "tweets.js")
  old_date = Time.iso8601("#{old_day}T12:00:00+09:00").strftime("%a %b %d %H:%M:%S %z %Y")
  write_tweets(archive_file, [tweet("300", text: "過去の投稿", date: old_date)])
  history = File.join(directory, "history")
  vault = File.join(directory, "vault")
  config = {
    "x" => { "handle" => "self", "archive_dir" => history },
    "obsidian" => { "vault_path" => vault, "timezone" => "Asia/Tokyo", "posts" => { "days" => 1 } }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  old_note = File.join(vault, "Daily", "#{old_day}.md")

  _stdout, stderr, status = run_script("--config", config_path, archive_file)
  assert_equal(true, status.success?, "limited archive import succeeds: #{stderr}")
  assert_equal(false, File.exist?(old_note), "configured days excludes old notes by default")
  assert_equal(["300"], XFeed.read_archive(history).map { |item| item.fetch("id") }, "the date limit does not discard archived history")

  _stdout, stderr, status = run_script("--config", config_path, archive_file, "--all")
  assert_equal(true, status.success?, "all-history archive import succeeds: #{stderr}")
  assert_equal(true, File.read(old_note).include?("過去の投稿"), "--all overrides the configured days limit")
  note_before = File.binread(old_note)
  history_before = File.binread(File.join(history, "posts.jsonl"))
  _stdout, _stderr, status = run_script("--config", config_path, archive_file, "--all", "--days", "1")
  assert_equal(false, status.success?, "--all and --days cannot be combined")
  assert_equal(note_before, File.binread(old_note), "conflicting date options do not change notes")
  assert_equal(history_before, File.binread(File.join(history, "posts.jsonl")), "conflicting date options do not change history")
end

puts "x_archive_test: ok"
