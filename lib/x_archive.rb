# frozen_string_literal: true

require "cgi"
require "json"
require "open3"
require "time"

module XArchive
  module_function

  def tweet_file?(name)
    name.match?(/\Atweets?(?:-part\d+)?\.js\z/)
  end

  def zip_output(*args)
    output, error, status = Open3.capture3("unzip", *args)
    raise ArgumentError, "cannot read X archive ZIP: #{error.strip}" unless status.success?

    output
  end

  def sources(path)
    path = File.expand_path(path)
    if File.directory?(path)
      data_dir = File.directory?(File.join(path, "data")) ? File.join(path, "data") : path
      files = Dir.children(data_dir).select { |name| tweet_file?(name) }.sort
      return files.map { |name| [File.join(data_dir, name), nil] } unless files.empty?

      zips = Dir.glob(File.join(path, "*.zip"))
      raise ArgumentError, "expected one X archive ZIP in #{path}" unless zips.size == 1

      return sources(zips.first)
    end

    if File.extname(path).casecmp?(".zip")
      entries = zip_output("-Z1", path).lines.map(&:chomp).select do |entry|
        entry.start_with?("data/") && tweet_file?(entry.delete_prefix("data/"))
      end.sort
      raise ArgumentError, "duplicate tweet files in X archive ZIP" unless entries.uniq.size == entries.size
      raise ArgumentError, "no tweet files in X archive ZIP" if entries.empty?

      entries.map { |entry| [entry, path] }
    else
      raise ArgumentError, "X archive file not found: #{path}" unless File.file?(path)

      [[path, nil]]
    end
  end

  def parse(path, handle:)
    handle = handle.to_s.delete_prefix("@")
    raise ArgumentError, "x.handle is required" unless handle.match?(/\A[A-Za-z0-9_]+\z/)

    sources(path).flat_map do |name, zip|
      data = zip ? zip_output("-p", zip, name) : File.binread(name)
      data = data.force_encoding(Encoding::UTF_8).delete_prefix("\uFEFF")
      match = data.match(/\A\s*window\.YTD\.tweets?\.part\d+\s*=\s*/)
      raise ArgumentError, "invalid X archive header: #{name}" unless match

      records = JSON.parse(data[match.end(0)..].sub(/;\s*\z/, ""))
      raise ArgumentError, "expected X archive array: #{name}" unless records.is_a?(Array)

      records.filter_map do |entry|
        tweet = entry.is_a?(Hash) && entry["tweet"]
        raise ArgumentError, "invalid tweet in #{name}" unless tweet.is_a?(Hash)

        id = tweet["id_str"] || tweet["id"]
        text = tweet["full_text"]
        raise ArgumentError, "invalid tweet ID in #{name}" unless id.is_a?(String) && id.match?(/\A\d+\z/)
        raise ArgumentError, "invalid tweet text in #{name}" unless text.is_a?(String)
        raise ArgumentError, "invalid tweet date in #{name}" unless tweet["created_at"].is_a?(String)

        created_at = Time.parse(tweet["created_at"]).utc.iso8601
        next if text.match?(/\ART @[A-Za-z0-9_]+:/)

        entities = tweet["entities"].is_a?(Hash) ? tweet["entities"] : {}
        (Array(entities["urls"]) + Array(entities["media"])).each do |link|
          next unless link.is_a?(Hash) && link["url"].is_a?(String) && link["expanded_url"].is_a?(String)
          next if link["url"].empty? || link["expanded_url"].empty?

          text = text.gsub(link["url"]) { link["expanded_url"] }
        end
        {
          "id" => id,
          "author" => handle,
          "url" => "https://x.com/#{handle}/status/#{id}",
          "created_at" => created_at,
          "text" => CGI.unescapeHTML(text)
        }
      end
    end
  end
end
