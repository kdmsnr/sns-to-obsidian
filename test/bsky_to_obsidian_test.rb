#!/usr/bin/env ruby
# frozen_string_literal: true

require "cbor"
require "digest"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "../bsky_to_obsidian"

DID = "did:plc:self"
OTHER_DID = "did:plc:other"

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

def feed_entry(id, text: id, date: "2026-09-19T15:05:00Z", did: DID, parent: nil, reason: nil)
  record = { "$type" => BskyFeed::COLLECTION, "text" => text, "createdAt" => date }
  if parent
    record["reply"] = {
      "parent" => { "uri" => "at://#{parent}/app.bsky.feed.post/parent" },
      "root" => { "uri" => "at://#{parent}/app.bsky.feed.post/root" }
    }
  end
  entry = { "post" => { "uri" => "at://#{did}/app.bsky.feed.post/#{id}", "author" => { "did" => did }, "record" => record } }
  entry["reason"] = { "$type" => reason } if reason
  entry
end

def archive_item(entry)
  post = entry.fetch("post")
  BskyFeed.normalize({
    "repo_did" => DID, "path" => post.fetch("uri").delete_prefix("at://#{DID}/"), "record" => post.fetch("record")
  }, DID)
end

def fake_request(pages, calls)
  lambda do |method, params|
    calls << [method, params]
    page = pages.fetch(params["cursor"])
    raise page if page.is_a?(Exception)

    page
  end
end

def fake_client(pages, calls = [])
  request = fake_request(pages, calls)
  Object.new.tap do |client|
    client.define_singleton_method(:resolve_actor) do |actor|
      raise "unexpected actor: #{actor}" unless [DID, "self.example"].include?(actor)

      DID
    end
    client.define_singleton_method(:fetch_latest) do |did, known_uris:|
      BskyFeed.fetch_latest(did, known_uris: known_uris, request: request)
    end
  end
end

def quiet
  old_stdout = $stdout
  $stdout = StringIO.new
  yield
ensure
  $stdout = old_stdout
end

assert_equal(
  "self.example",
  bluesky_actor_config({ "bluesky" => { "handle" => "self.example", "feed_url" => "https://bsky.app/profile/#{OTHER_DID}/rss" } }),
  "the account is independent of the RSS URL"
)
assert_raises("an RSS URL cannot substitute for an explicit account") do
  bluesky_actor_config({ "bluesky" => { "feed_url" => "https://bsky.app/profile/#{DID}/rss" } })
end

# A known self-repost or another author's post cannot end a catch-up fetch.
old = archive_item(feed_entry("old", date: "2026-09-19T15:00:00Z"))
calls = []
pages = {
  nil => { "feed" => [
    feed_entry("old", reason: "app.bsky.feed.defs#reasonRepost"),
    feed_entry("someone", did: OTHER_DID),
    feed_entry("new")
  ], "cursor" => "page-2" },
  "page-2" => { "feed" => [
    feed_entry("middle"),
    feed_entry("old", text: "updated"),
    feed_entry("after-boundary")
  ], "cursor" => "must-not-fetch" }
}
incoming = BskyFeed.fetch_latest(DID, known_uris: [old["uri"]], request: fake_request(pages, calls))
assert_equal(2, calls.size, "catch-up paginates until a known original post")
assert_equal("posts_with_replies", calls.first.last["filter"], "the API includes self replies")
assert_equal(false, calls.first.last["includePins"], "pinned posts do not truncate catch-up")
assert_equal(100, calls.first.last["limit"], "the API uses full pages")
assert_equal(%w[old new middle old after-boundary], incoming.map { |post| post["rkey"] }, "other authors are omitted and the whole boundary page is consumed")
merged = BskyFeed.merge([old], incoming)
assert_equal(4, merged.size, "AT URIs deduplicate self-reposts")
assert_equal("updated", merged.find { |post| post["rkey"] == "old" }["record"]["text"], "re-fetched posts replace stored content")
assert_equal([old], BskyFeed.merge([old], []), "an empty feed retains history")

calls = []
no_overlap = { nil => { "feed" => [feed_entry("a")], "cursor" => "last" }, "last" => { "feed" => [feed_entry("b")] } }
assert_equal(2, BskyFeed.fetch_latest(DID, known_uris: [], request: fake_request(no_overlap, calls)).size, "without overlap the full available feed is read")
assert_equal(2, calls.size, "the final cursor ends pagination")
assert_raises("repeated cursors must fail rather than loop") do
  BskyFeed.fetch_latest(DID, known_uris: [], request: fake_request({
    nil => { "feed" => [], "cursor" => "loop" }, "loop" => { "feed" => [], "cursor" => "loop" }
  }, []))
end
assert_raises("invalid author feed responses must fail") do
  BskyFeed.fetch_latest(DID, known_uris: [], request: ->(*) { { "error" => "Unavailable" } })
end
assert_raises("invalid dates must fail before archiving") do
  BskyFeed.fetch_latest(DID, known_uris: [], request: ->(*) { { "feed" => [feed_entry("bad", date: "invalid")] } })
end

Dir.mktmpdir("bsky-to-obsidian-test") do |directory|
  out = File.join(directory, "out")
  vault = File.join(directory, "vault")
  FileUtils.mkdir_p([out, vault])
  config = {
    "bluesky" => { "handle" => "self.example", "out_dir" => out, "car_path" => File.join(directory, "missing.car") },
    "obsidian" => { "vault_path" => vault, "timezone" => "Asia/Tokyo", "daily" => { "path_format" => "%Y-%m-%d.md" },
                    "posts" => { "exclude_texts" => ["excluded"] } }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  seed = File.join(out, "records.jsonl")
  archive = File.join(out, "posts.jsonl")
  historical = archive_item(feed_entry("historical", date: "2020-01-01T00:00:00Z"))
  File.write(seed, [historical, old].map { |post| JSON.generate(post.reject { |key, _| key == "uri" }) }.join("\n"))
  note_path = File.join(vault, "2026-09-20.md")
  x_block = "<!-- x-to-obsidian:start -->\nX 本文\n<!-- x-to-obsidian:end -->"
  File.write(note_path, "# 手書き\n\n#{x_block}\n")
  self_reply = feed_entry("self-reply", text: "自分への返信", parent: DID)
  other_reply = feed_entry("other-reply", text: "他人への返信", parent: OTHER_DID)
  linked = feed_entry("linked", text: "資料 example.com/…")
  linked["post"]["record"]["facets"] = [{
    "index" => { "byteStart" => "資料 ".bytesize, "byteEnd" => "資料 example.com/…".bytesize },
    "features" => [{ "$type" => "app.bsky.richtext.facet#link", "uri" => "https://example.com/full/path" }]
  }]
  page = { "feed" => [self_reply, other_reply, linked, feed_entry("excluded"), feed_entry("old")] }
  client = fake_client({ nil => page })
  quiet { BskyToObsidian.main(["--config", config_path], client: client) }
  posts = BskyFeed.read_posts(archive, DID)
  assert_equal(6, posts.size, "CAR history is seeded and all own API records are archived")
  assert_equal(true, posts.any? { |post| post["rkey"] == "historical" }, "older history survives API rollover")
  note = File.read(note_path)
  assert_equal(true, note.include?("# 手書き") && note.include?(x_block), "handwritten text and X blocks survive")
  assert_equal(true, note.include?("自分への返信"), "self replies are written")
  assert_equal(false, note.include?("他人への返信"), "replies to other users are omitted")
  assert_equal(false, note.include?("excluded"), "excluded text stays out of notes")
  assert_equal(true, note.include?("資料 https://example.com/full/path"), "UTF-8 facet links retain full URLs")
  assert_equal(true, note.include?("00:05"), "API posts use the configured timezone")

  # Once seeded, stale or missing CAR/extraction inputs are no longer needed.
  File.write(seed, "invalid old extraction")
  initial_archive = File.binread(archive)
  initial_mtime = File.mtime(note_path)
  quiet { BskyToObsidian.main(["--config", config_path], client: client) }
  assert_equal(initial_archive, File.binread(archive), "repeat imports are idempotent")
  assert_equal(initial_mtime, File.mtime(note_path), "unchanged notes are not rewritten")

  failed_client = fake_client({
    nil => { "feed" => [feed_entry("not-committed")], "cursor" => "fail" },
    "fail" => RuntimeError.new("network unavailable")
  })
  assert_raises("a later page failure aborts the entire sync") do
    quiet { BskyToObsidian.main(["--config", config_path], client: failed_client) }
  end
  assert_equal(initial_archive, File.binread(archive), "a failed fetch leaves the archive intact")
  assert_equal(note, File.read(note_path), "a failed fetch leaves daily notes intact")
  quiet { BskyToObsidian.main(["--config", config_path], client: fake_client({ nil => { "feed" => [] } })) }
  assert_equal(initial_archive, File.binread(archive), "an empty API response cannot erase the archive")

  # Offline mode can replay an interrupted note update, without contacting any API.
  File.write(note_path, "# 手書き\n\n#{x_block}\n")
  quiet { BskyToObsidian.main(["--config", config_path, "--offline"], client: Object.new) }
  assert_equal(note, File.read(note_path), "offline replay rebuilds notes after an interrupted write")

  assert_raises("mixing accounts in one archive must fail") { BskyFeed.read_posts(archive, OTHER_DID) }
  assert_raises("CAR refresh is not part of the API command") { BskyToObsidian.parse_options(["--refresh-car"]) }
end

# Generate a minimal CAR so initial extraction is exercised without user data.
def varint(number)
  bytes = []
  while number >= 128
    bytes << ((number & 127) | 128)
    number >>= 7
  end
  (bytes << number).pack("C*")
end

def write_car(path, record, did: DID)
  blocks = []
  add_block = lambda do |data|
    encoded = CBOR.encode(data)
    cid = [1, 0x71, 0x12, 32].pack("C*") + Digest::SHA256.digest(encoded)
    blocks << cid + encoded
    CBOR::Tagged.new(42, "\x00".b + cid)
  end
  record_cid = add_block.call(record)
  tree_cid = add_block.call({ "e" => [{ "p" => 0, "k" => "app.bsky.feed.post/car-post", "v" => record_cid }] })
  commit_cid = add_block.call({ "did" => did, "data" => tree_cid })
  header = CBOR.encode({ "version" => 1, "roots" => [commit_cid] })
  File.binwrite(path, varint(header.bytesize) + header + blocks.map { |block| varint(block.bytesize) + block }.join)
end

def run_car_script(*args)
  Open3.capture3(RbConfig.ruby, File.expand_path("../bsky_car_to_obsidian.rb", __dir__), *args)
end

Dir.mktmpdir("bsky-car-import-test") do |directory|
  out = File.join(directory, "out")
  vault = File.join(directory, "vault")
  car = File.join(directory, "repo.car")
  config = {
    "bluesky" => { "did" => DID, "out_dir" => out, "car_path" => car },
    "obsidian" => { "vault_path" => vault, "timezone" => "UTC", "posts" => { "days" => 1 } }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  write_car(car, feed_entry("car-post", text: "CAR 本文", date: "2020-01-01T00:00:00Z")["post"]["record"])
  FileUtils.mkdir_p(out)
  posts_path = File.join(out, "posts.jsonl")
  old = archive_item(feed_entry("old", text: "API 本文", date: "2020-01-02T00:00:00Z"))
  BskyFeed.write_archive(posts_path, [old])
  seed_path = File.join(out, "records.jsonl")
  seed_data = JSON.generate(archive_item(feed_entry("seed", date: "2019-01-01T00:00:00Z"))) + "\n"
  File.write(seed_path, seed_data)
  note_path = File.join(vault, "Daily", "2020-01-01.md")
  FileUtils.mkdir_p(File.dirname(note_path))
  File.write(note_path, "# 手書き\n")

  _stdout, stderr, status = run_car_script("--config", config_path)
  assert_equal(true, status.success?, "CAR can be imported using a configured DID and path: #{stderr}")
  posts = BskyFeed.read_posts(posts_path, DID)
  assert_equal(%w[car-post old], posts.map { |post| post["rkey"] }, "CAR posts merge with existing history")
  assert_equal("# 手書き\n", File.read(note_path), "configured days limits note updates, not the archive")
  assert_equal(seed_data, File.read(seed_path), "import does not overwrite the legacy extraction")

  _stdout, stderr, status = run_car_script("--config", config_path, "--all", car)
  assert_equal(true, status.success?, "--all and an explicit CAR path work: #{stderr}")
  note = File.read(note_path)
  assert_equal(true, note.include?("# 手書き") && note.include?("CAR 本文"), "--all writes older posts and preserves handwritten content")
  saved = File.binread(posts_path)
  _stdout, stderr, status = run_car_script("--config", config_path, "--all", car)
  assert_equal(true, status.success?, "repeat CAR import succeeds: #{stderr}")
  assert_equal(saved, File.binread(posts_path), "repeat import is idempotent")
  assert_equal(note, File.read(note_path), "repeat import leaves notes unchanged")

  bad_car = File.join(directory, "bad.car")
  File.write(bad_car, "broken CAR")
  other_car = File.join(directory, "other.car")
  write_car(other_car, feed_entry("car-post", text: "other")["post"]["record"], did: OTHER_DID)
  [bad_car, other_car, File.join(directory, "missing.car")].each do |path|
    _stdout, _stderr, status = run_car_script("--config", config_path, path)
    assert_equal(false, status.success?, "invalid or foreign CAR is rejected")
    assert_equal(saved, File.binread(posts_path), "failed CAR import preserves history")
    assert_equal(note, File.read(note_path), "failed CAR import preserves notes")
    assert_equal(seed_data, File.read(seed_path), "failed CAR import preserves old extraction")
  end
  _stdout, _stderr, status = run_car_script("--config", config_path, "--all", "--days", "1", car)
  assert_equal(false, status.success?, "--all and --days conflict")
  assert_equal(saved, File.binread(posts_path), "invalid options leave history intact")
end

Dir.mktmpdir("bsky-car-legacy-seed-test") do |directory|
  out = File.join(directory, "out")
  FileUtils.mkdir_p(out)
  car = File.join(directory, "repo.car")
  write_car(car, feed_entry("car-post", text: "CAR 本文")["post"]["record"])
  legacy = archive_item(feed_entry("legacy", date: "2020-01-01T00:00:00Z"))
  File.write(File.join(out, "records.jsonl"), JSON.generate(legacy.reject { |key, _| key == "uri" }) + "\n")
  config = {
    "bluesky" => { "did" => DID, "out_dir" => out, "car_path" => car },
    "obsidian" => { "vault_path" => File.join(directory, "vault") }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  _stdout, stderr, status = run_car_script("--config", config_path)
  assert_equal(true, status.success?, "CAR import supports existing legacy extraction: #{stderr}")
  posts = BskyFeed.read_posts(File.join(out, "posts.jsonl"), DID)
  assert_equal(%w[car-post legacy], posts.map { |post| post["rkey"] }.sort, "legacy records are retained when no posts archive exists")
end

Dir.mktmpdir("bsky-api-without-car-test") do |directory|
  out = File.join(directory, "out")
  config = {
    "bluesky" => { "did" => DID, "out_dir" => out, "car_path" => File.join(directory, "missing.car") },
    "obsidian" => { "vault_path" => File.join(directory, "vault") }
  }
  config_path = File.join(directory, "config.yml")
  File.write(config_path, YAML.dump(config))
  quiet do
    BskyToObsidian.main(["--config", config_path], client: fake_client({ nil => { "feed" => [feed_entry("new")] } }))
  end
  assert_equal(["new"], BskyFeed.read_posts(File.join(out, "posts.jsonl"), DID).map { |post| post["rkey"] }, "API works without downloading or extracting a CAR")
  assert_equal(false, File.exist?(config["bluesky"]["car_path"]), "normal API sync does not create a CAR")
end

puts "bsky_to_obsidian_test: ok"
