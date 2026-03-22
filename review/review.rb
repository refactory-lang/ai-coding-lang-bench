#!/usr/bin/env ruby
# frozen_string_literal: true

# Single-pass code review via Claude API (non-agentic).
#
# Makes a direct Anthropic API call (not Claude Code) for reproducible,
# non-agentic code review. Temperature 0, no tool use, structured JSON output.
#
# Usage:
#   ruby review/review.rb --source DIR --lang LANG [--model MODEL] [--manifest FILE]
#
# Options:
#   --source DIR       Directory containing a (bugged) MiniGit implementation
#   --lang LANG        Language of the implementation
#   --model MODEL      Claude model to use (default: claude-sonnet-4-6-20250514)
#   --manifest FILE    Bug manifest for ground truth (optional, for logging only)
#   --output FILE      Output JSON file (default: stdout)
#   --spec FILE        MiniGit spec file for context (default: SPEC-v2.txt)

require 'json'
require 'net/http'
require 'uri'

BASE_DIR = File.expand_path('..', __dir__)

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------

source_dir = nil
lang = nil
model = 'claude-sonnet-4-6-20250514'
manifest_path = nil
output_path = nil
spec_path = File.join(BASE_DIR, 'SPEC-v2.txt')

i = 0
while i < ARGV.length
  case ARGV[i]
  when '--source'
    source_dir = File.expand_path(ARGV[i + 1])
    i += 2
  when '--lang'
    lang = ARGV[i + 1]
    i += 2
  when '--model'
    model = ARGV[i + 1]
    i += 2
  when '--manifest'
    manifest_path = File.expand_path(ARGV[i + 1])
    i += 2
  when '--output'
    output_path = File.expand_path(ARGV[i + 1])
    i += 2
  when '--spec'
    spec_path = File.expand_path(ARGV[i + 1])
    i += 2
  else
    i += 1
  end
end

unless source_dir && lang
  puts "Usage: ruby review/review.rb --source DIR --lang LANG [--model MODEL]"
  exit 1
end

api_key = ENV['ANTHROPIC_API_KEY']
unless api_key
  puts "ERROR: ANTHROPIC_API_KEY environment variable is required"
  exit 1
end

# ---------------------------------------------------------------------------
# Read source files
# ---------------------------------------------------------------------------

def read_source_files(dir, lang)
  exts = case lang
         when 'python' then %w[py]
         when 'rust' then %w[rs]
         when 'javascript' then %w[js]
         when 'typescript' then %w[ts]
         when 'go' then %w[go]
         when 'c' then %w[c h]
         when 'ruby' then %w[rb]
         else %w[*]
         end

  files = exts.flat_map { |e| Dir.glob(File.join(dir, '**', "*.#{e}")) }

  # Also check the minigit executable itself
  minigit = File.join(dir, 'minigit')
  if File.exist?(minigit) && !files.include?(minigit)
    content = File.read(minigit, encoding: 'UTF-8') rescue nil
    files << minigit if content&.valid_encoding?
  end

  files.reject { |f| f.include?('/node_modules/') || f.include?('/target/') || f.include?('/.minigit/') }
       .map { |f| { path: f.sub("#{dir}/", ''), content: File.read(f, encoding: 'UTF-8') } }
end

source_files = read_source_files(source_dir, lang)

if source_files.empty?
  puts "ERROR: No source files found in #{source_dir}"
  exit 1
end

# Build source code context
source_context = source_files.map { |f| "=== #{f[:path]} ===\n#{f[:content]}" }.join("\n\n")

# Read spec for context
spec_content = File.exist?(spec_path) ? File.read(spec_path) : ''

# ---------------------------------------------------------------------------
# Build review prompt
# ---------------------------------------------------------------------------

system_prompt = <<~SYSTEM
  You are a code reviewer specializing in finding logic bugs. You are reviewing a #{lang} implementation of MiniGit, a minimal version control system.

  Your task: carefully review the code for logic bugs — errors that would cause incorrect behavior on edge cases or untested paths. Focus on:
  - Off-by-one errors in loops and indexing
  - Boundary condition failures (empty inputs, single elements, large inputs)
  - Incorrect sort orders or comparison logic
  - Hash function implementation errors
  - State management bugs (index not cleared, HEAD not updated, etc.)
  - Missing error handling for edge cases
  - Silent data corruption or truncation

  Do NOT report:
  - Style issues, naming conventions, or code organization
  - Missing features that aren't in the spec
  - Performance concerns
  - Security issues unrelated to correctness

  Respond with a JSON object (no markdown, no explanation outside the JSON) with this exact structure:
  {
    "bugs_found": [
      {
        "file": "filename",
        "line": line_number_or_null,
        "description": "brief description of the bug",
        "confidence": 0.0_to_1.0,
        "bug_type": "off-by-one|boundary-condition|sort-order|hash-collision|index-error|silent-truncation|state-leak|other",
        "severity": "high|medium|low"
      }
    ],
    "review_summary": "one paragraph summarizing the code quality and any patterns noticed"
  }
SYSTEM

user_prompt = <<~USER
  ## MiniGit Specification

  #{spec_content}

  ## Source Code (#{lang})

  #{source_context}

  Review this implementation for logic bugs. Return your findings as JSON.
USER

# ---------------------------------------------------------------------------
# Call Claude API
# ---------------------------------------------------------------------------

$stderr.puts "Reviewing #{source_dir} (#{lang}) with #{model}..."

uri = URI('https://api.anthropic.com/v1/messages')
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
http.read_timeout = 120

request = Net::HTTP::Post.new(uri)
request['content-type'] = 'application/json'
request['x-api-key'] = api_key
request['anthropic-version'] = '2023-06-01'
# Request extended thinking to get thinking token breakdown
request['anthropic-beta'] = 'output-128k-2025-02-19'

body = {
  model: model,
  max_tokens: 4096,
  temperature: 0,
  system: system_prompt,
  messages: [{ role: 'user', content: user_prompt }],
}

start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
response = http.request(request, JSON.generate(body))
elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

unless response.code.to_i == 200
  $stderr.puts "ERROR: API returned #{response.code}: #{response.body}"
  exit 1
end

result = JSON.parse(response.body)

# ---------------------------------------------------------------------------
# Parse response
# ---------------------------------------------------------------------------

# Extract text content
text_content = result['content']&.select { |c| c['type'] == 'text' }&.map { |c| c['text'] }&.join('')

# Parse the JSON response from Claude
review_data = begin
  JSON.parse(text_content)
rescue JSON::ParserError
  # Try to extract JSON from markdown code block
  if text_content =~ /```(?:json)?\s*(\{.*?\})\s*```/m
    JSON.parse($1)
  else
    { 'bugs_found' => [], 'review_summary' => text_content, 'parse_error' => true }
  end
end

# Extract usage
usage = result['usage'] || {}

# Build output
output = {
  language: lang,
  source_dir: source_dir,
  model: model,
  bugs_found: review_data['bugs_found'] || [],
  review_summary: review_data['review_summary'] || '',
  usage: {
    input_tokens: usage['input_tokens'] || 0,
    output_tokens: usage['output_tokens'] || 0,
    thinking_tokens: usage['thinking_tokens'] || 0,
    cache_read_tokens: usage['cache_read_input_tokens'] || 0,
    cache_creation_tokens: usage['cache_creation_input_tokens'] || 0,
    total_cost_usd: estimate_cost(usage, model),
  },
  review_time_ms: elapsed_ms,
}

# Add manifest info if available
if manifest_path && File.exist?(manifest_path)
  output[:manifest] = JSON.parse(File.read(manifest_path))
end

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

json_output = JSON.pretty_generate(output)

if output_path
  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, json_output)
  $stderr.puts "Review saved to #{output_path}"
else
  puts json_output
end

$stderr.puts "Review complete: #{output[:bugs_found].length} bugs found, #{elapsed_ms}ms, #{usage['input_tokens']} input / #{usage['output_tokens']} output tokens"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

BEGIN {
  def estimate_cost(usage, model)
    input = usage['input_tokens'] || 0
    output = usage['output_tokens'] || 0

    # Approximate pricing (per 1K tokens)
    case model
    when /opus/
      input * 0.015 / 1000.0 + output * 0.075 / 1000.0
    when /sonnet/
      input * 0.003 / 1000.0 + output * 0.015 / 1000.0
    when /haiku/
      input * 0.00025 / 1000.0 + output * 0.00125 / 1000.0
    else
      input * 0.003 / 1000.0 + output * 0.015 / 1000.0
    end
  end
}
