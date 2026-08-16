#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "rexml/document"
require "uri"

cldr_release = ENV.fetch("CLDR_RELEASE", "release-48-2")
source_url = "https://raw.githubusercontent.com/unicode-org/cldr/#{cldr_release}/common/annotations/en.xml"
package_dir = File.expand_path("..", __dir__)
output_file = File.join(
  package_dir,
  "Sources",
  "Quagmire",
  "Resources",
  "EmojiAnnotations",
  "emoji-annotations-en.json"
)

response = Net::HTTP.get_response(URI(source_url))
abort "Failed to download #{source_url}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

entries = Hash.new { |hash, character| hash[character] = { "keywords" => [] } }
document = REXML::Document.new(response.body)
document.elements.each("/ldml/annotations/annotation") do |annotation|
  character = annotation.attributes["cp"]
  value = annotation.text.to_s.strip
  next if character.nil? || value.empty?

  if annotation.attributes["type"] == "tts"
    entries[character]["name"] = value
  else
    entries[character]["keywords"] = value.split("|").map(&:strip).reject(&:empty?)
  end
end

payload = {
  "metadata" => {
    "cldrRelease" => cldr_release,
    "source" => source_url,
    "license" => "Unicode-3.0",
    "copyright" => "Copyright © 1991-2025 Unicode, Inc."
  },
  "annotations" => entries.sort.to_h
}

FileUtils.mkdir_p(File.dirname(output_file))
File.write(output_file, JSON.generate(payload) + "\n")
puts "Wrote #{entries.count} annotations to #{output_file}"
