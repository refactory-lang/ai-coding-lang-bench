#!/usr/bin/env ruby
# frozen_string_literal: true

# Batch review runner for Track 1 experiments (A and B).
#
# Orchestrates bug injection + review across all conditions:
#   Experiment A: Python vs Rust (paired by functional equivalence)
#   Experiment B: Vanilla Python vs Constrained Python vs Rust
#
# Usage:
#   ruby review/batch_review.rb --experiment a|b [--trials N] [--seed S]
#
# Options:
#   --experiment a|b   Which experiment to run
#   --trials N         Number of trials to review (default: 20)
#   --start N          Starting trial number (default: 1)
#   --seed S           Random seed for bug selection reproducibility
#   --bug-count N      Bugs per implementation (default: 4, range: 3-5)
#   --model MODEL      Review model (default: claude-sonnet-4-6-20250514)
#   --source-dir DIR   Directory containing generated implementations
#   --output-dir DIR   Directory for review results (default: review/results/)
#   --dry-run          Show plan without executing

require 'json'
require 'fileutils'

BASE_DIR = File.expand_path('..', __dir__)

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------

experiment = nil
trials = 20
start_trial = 1
seed = 42
bug_count = 4
model = 'claude-sonnet-4-6-20250514'
source_dir = File.join(BASE_DIR, 'generated')
output_dir = File.join(BASE_DIR, 'review', 'results')
dry_run = false

i = 0
while i < ARGV.length
  case ARGV[i]
  when '--experiment', '-e'
    experiment = ARGV[i + 1].downcase
    i += 2
  when '--trials', '-t'
    trials = ARGV[i + 1].to_i
    i += 2
  when '--start', '-s'
    start_trial = ARGV[i + 1].to_i
    i += 2
  when '--seed'
    seed = ARGV[i + 1].to_i
    i += 2
  when '--bug-count'
    bug_count = ARGV[i + 1].to_i
    i += 2
  when '--model'
    model = ARGV[i + 1]
    i += 2
  when '--source-dir'
    source_dir = File.expand_path(ARGV[i + 1])
    i += 2
  when '--output-dir'
    output_dir = File.expand_path(ARGV[i + 1])
    i += 2
  when '--dry-run'
    dry_run = true
    i += 1
  else
    i += 1
  end
end

unless experiment && %w[a b].include?(experiment)
  puts "Usage: ruby review/batch_review.rb --experiment a|b [--trials N]"
  exit 1
end

# ---------------------------------------------------------------------------
# Build review plan
# ---------------------------------------------------------------------------

# Experiment A: Python vs Rust
# Experiment B: Python vs Constrained Python vs Rust
conditions = case experiment
             when 'a' then %w[python rust]
             when 'b' then %w[python python-refactory rust]
             end

plan = []

(start_trial...(start_trial + trials)).each do |trial|
  conditions.each do |condition|
    # Map condition to directory name
    dir_name = case condition
               when 'python-refactory' then 'python-refactory'
               else condition
               end

    impl_dir = File.join(source_dir, "minigit-#{dir_name}-#{trial}-v2")

    plan << {
      trial: trial,
      condition: condition,
      lang: condition.sub('-refactory', ''),  # Language for injection/review
      source_dir: impl_dir,
      seed: seed + trial,  # Deterministic per-trial seed
    }
  end
end

puts "=" * 60
puts "Experiment #{experiment.upcase} — Batch Review"
puts "=" * 60
puts
puts "Conditions: #{conditions.join(', ')}"
puts "Trials: #{start_trial}..#{start_trial + trials - 1} (#{trials} trials)"
puts "Bug count: #{bug_count} per implementation"
puts "Model: #{model}"
puts "Seed: #{seed}"
puts "Source: #{source_dir}"
puts "Output: #{output_dir}"
puts
puts "Total reviews: #{plan.length}"
puts

if dry_run
  puts "[DRY RUN] Review plan:"
  plan.each do |p|
    exists = File.directory?(p[:source_dir]) ? 'EXISTS' : 'MISSING'
    puts "  Trial #{p[:trial]} #{p[:condition]}: #{p[:source_dir]} [#{exists}]"
  end
  exit 0
end

# ---------------------------------------------------------------------------
# Execute reviews
# ---------------------------------------------------------------------------

FileUtils.mkdir_p(output_dir)

inject_script = File.join(BASE_DIR, 'bugs', 'inject.rb')
review_script = File.join(BASE_DIR, 'review', 'review.rb')

results = []
skipped = []

plan.each_with_index do |p, idx|
  puts "-" * 60
  puts "Review #{idx + 1}/#{plan.length}: Trial #{p[:trial]}, #{p[:condition]}"
  puts "-" * 60

  unless File.directory?(p[:source_dir])
    puts "  SKIPPED: #{p[:source_dir]} not found"
    skipped << p
    next
  end

  bugged_dir = "#{p[:source_dir]}-bugged"
  review_output = File.join(output_dir, "experiment-#{experiment}",
                            "trial-#{p[:trial]}-#{p[:condition]}.json")

  # Step 1: Inject bugs
  puts "  Injecting #{bug_count} bugs..."
  inject_cmd = "ruby #{inject_script} --source #{p[:source_dir]} --lang #{p[:lang]} " \
               "--count #{bug_count} --seed #{p[:seed]} --output #{bugged_dir}"
  system(inject_cmd)

  unless File.directory?(bugged_dir)
    puts "  SKIPPED: Bug injection failed"
    skipped << p
    next
  end

  # Step 2: Review
  puts "  Running review..."
  manifest = File.join(bugged_dir, '.bug-manifest.json')
  review_cmd = "ruby #{review_script} --source #{bugged_dir} --lang #{p[:lang]} " \
               "--model #{model} --output #{review_output}"
  review_cmd += " --manifest #{manifest}" if File.exist?(manifest)
  system(review_cmd)

  if File.exist?(review_output)
    review_data = JSON.parse(File.read(review_output))
    results << {
      trial: p[:trial],
      condition: p[:condition],
      bugs_found: review_data['bugs_found']&.length || 0,
      review_time_ms: review_data['review_time_ms'] || 0,
      input_tokens: review_data.dig('usage', 'input_tokens') || 0,
      output_tokens: review_data.dig('usage', 'output_tokens') || 0,
      thinking_tokens: review_data.dig('usage', 'thinking_tokens') || 0,
    }
    puts "  Done: #{review_data['bugs_found']&.length || 0} bugs found"
  else
    puts "  SKIPPED: Review failed to produce output"
    skipped << p
  end

  # Cleanup bugged dir to save space
  FileUtils.rm_rf(bugged_dir)

  puts
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

puts "=" * 60
puts "Experiment #{experiment.upcase} — Summary"
puts "=" * 60
puts
puts "Completed: #{results.length}/#{plan.length}"
puts "Skipped: #{skipped.length}"
puts

if results.any?
  conditions.each do |cond|
    cond_results = results.select { |r| r[:condition] == cond }
    next if cond_results.empty?

    avg_bugs = cond_results.sum { |r| r[:bugs_found] }.to_f / cond_results.length
    avg_time = cond_results.sum { |r| r[:review_time_ms] }.to_f / cond_results.length
    avg_input = cond_results.sum { |r| r[:input_tokens] }.to_f / cond_results.length
    avg_thinking = cond_results.sum { |r| r[:thinking_tokens] }.to_f / cond_results.length

    puts "#{cond} (#{cond_results.length} reviews):"
    puts "  Avg bugs found:     #{avg_bugs.round(1)}"
    puts "  Avg review time:    #{(avg_time / 1000).round(1)}s"
    puts "  Avg input tokens:   #{avg_input.round(0)}"
    puts "  Avg thinking tokens: #{avg_thinking.round(0)}"
    puts
  end
end

# Save aggregate results
agg_path = File.join(output_dir, "experiment-#{experiment}", "summary.json")
FileUtils.mkdir_p(File.dirname(agg_path))
File.write(agg_path, JSON.pretty_generate({
  experiment: experiment,
  conditions: conditions,
  trials: trials,
  seed: seed,
  bug_count: bug_count,
  model: model,
  results: results,
  skipped: skipped.map { |s| { trial: s[:trial], condition: s[:condition], reason: 'missing or failed' } },
}))
puts "Aggregate results saved to #{agg_path}"
