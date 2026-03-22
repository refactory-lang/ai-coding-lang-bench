#!/usr/bin/env ruby
# frozen_string_literal: true

# Token analysis script for the Refactory Benchmark Programme.
#
# Extracts token breakdowns from benchmark results, computes per-language
# aggregates, thinking-stability metrics (CV, heavy-thinking run counts),
# and statistical tests.
#
# Usage: ruby analysis/token_analysis.rb [results/results.json]

require 'json'

results_path = ARGV[0] || File.join(__dir__, '..', 'results', 'results.json')
unless File.exist?(results_path)
  puts "ERROR: Results file not found: #{results_path}"
  exit 1
end

results = JSON.parse(File.read(results_path))

# ---------------------------------------------------------------------------
# Aggregate per-language token statistics
# ---------------------------------------------------------------------------

by_language = Hash.new { |h, k| h[k] = [] }
results.each do |r|
  lang = r['language']
  %w[v1_claude v2_claude].each do |phase|
    claude = r[phase]
    next unless claude

    by_language[lang] << {
      trial: r['trial'],
      phase: phase,
      input_tokens: claude['input_tokens'] || 0,
      output_tokens: claude['output_tokens'] || 0,
      thinking_tokens: claude['thinking_tokens'] || 0,
      cache_creation_tokens: claude['cache_creation_tokens'] || 0,
      cache_read_tokens: claude['cache_read_tokens'] || 0,
      num_turns: claude['num_turns'] || 0,
      cost_usd: claude['cost_usd'] || 0.0,
      duration_ms: claude['duration_ms'] || 0,
      per_turn: claude['per_turn'] || [],
    }
  end
end

# ---------------------------------------------------------------------------
# Thinking stability analysis
# ---------------------------------------------------------------------------

def mean(arr)
  return 0.0 if arr.empty?
  arr.sum.to_f / arr.length
end

def stddev(arr)
  m = mean(arr)
  return 0.0 if arr.length < 2
  variance = arr.sum { |x| (x - m)**2 } / (arr.length - 1).to_f
  Math.sqrt(variance)
end

def cv(arr)
  m = mean(arr)
  return 0.0 if m.zero?
  (stddev(arr) / m * 100).round(1)
end

puts '=' * 70
puts 'Token Analysis — Per-Language Aggregates'
puts '=' * 70
puts

header = format('%-15s %8s %8s %8s %8s %8s %6s %7s',
                'Language', 'InTok', 'OutTok', 'ThinkTok', 'Turns', 'Cost$', 'IO%', 'CV%')
puts header
puts '-' * header.length

by_language.sort_by { |lang, _| lang }.each do |lang, entries|
  input = mean(entries.map { |e| e[:input_tokens] })
  output = mean(entries.map { |e| e[:output_tokens] })
  thinking = mean(entries.map { |e| e[:thinking_tokens] })
  turns = mean(entries.map { |e| e[:num_turns] })
  cost = mean(entries.map { |e| e[:cost_usd] })
  io_ratio = output.zero? ? 0.0 : (input / output).round(1)

  # Thinking stability: CV of output_tokens across trials
  # (proxy for thinking overhead variance when thinking_tokens not available)
  output_vals = entries.map { |e| e[:output_tokens] }
  stability_cv = cv(output_vals)

  puts format('%-15s %8d %8d %8d %8.1f %8.2f %5.1f:1 %6.1f%%',
              lang, input, output, thinking, turns, cost, io_ratio, stability_cv)
end

# ---------------------------------------------------------------------------
# Heavy-thinking run detection
# ---------------------------------------------------------------------------

puts
puts '=' * 70
puts 'Heavy-Thinking Runs (>2 stddev from language mean)'
puts '=' * 70
puts

by_language.sort_by { |lang, _| lang }.each do |lang, entries|
  output_vals = entries.map { |e| e[:output_tokens] }
  m = mean(output_vals)
  sd = stddev(output_vals)
  next if sd.zero?

  heavy = entries.select { |e| (e[:output_tokens] - m).abs > 2 * sd }
  next if heavy.empty?

  puts "#{lang}: #{heavy.length} heavy-thinking runs out of #{entries.length}"
  heavy.each do |e|
    puts "  Trial #{e[:trial]} (#{e[:phase]}): #{e[:output_tokens]} output tokens (mean=#{m.round(0)}, sd=#{sd.round(0)})"
  end
end

# ---------------------------------------------------------------------------
# Per-turn accumulation summary (if available)
# ---------------------------------------------------------------------------

has_per_turn = by_language.values.flatten.any? { |e| !e[:per_turn].empty? }

if has_per_turn
  puts
  puts '=' * 70
  puts 'Per-Turn Token Accumulation (first 5 languages with data)'
  puts '=' * 70
  puts

  shown = 0
  by_language.sort_by { |lang, _| lang }.each do |lang, entries|
    turn_data = entries.select { |e| !e[:per_turn].empty? }
    next if turn_data.empty?
    break if shown >= 5

    puts "--- #{lang} ---"
    # Average per-turn input tokens across trials
    max_turns = turn_data.map { |e| e[:per_turn].length }.max
    (0...max_turns).each do |t|
      turns_at_t = turn_data.map { |e| e[:per_turn][t] }.compact
      next if turns_at_t.empty?

      avg_input = mean(turns_at_t.map { |u| u['input_tokens'] || 0 })
      avg_output = mean(turns_at_t.map { |u| u['output_tokens'] || 0 })
      avg_thinking = mean(turns_at_t.map { |u| u['thinking_tokens'] || 0 })
      puts format("  Turn %2d: input=%7d  output=%6d  thinking=%6d  (n=%d)",
                  t + 1, avg_input, avg_output, avg_thinking, turns_at_t.length)
    end
    puts
    shown += 1
  end
else
  puts
  puts 'NOTE: No per-turn token data found. Re-run benchmark with updated harness to capture per-turn breakdowns.'
end

puts
puts 'Done.'
