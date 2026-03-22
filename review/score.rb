#!/usr/bin/env ruby
# frozen_string_literal: true

# Score review results against bug catalog ground truth.
#
# Computes defect detection rate (recall/precision/F1), false positive rate,
# and token cost breakdowns — stratified by language, bug type, and difficulty.
#
# Usage:
#   ruby review/score.rb --results DIR [--catalog FILE]
#
# Options:
#   --results DIR    Directory containing review result JSON files (experiment-a/ or experiment-b/)
#   --catalog FILE   Path to bug catalog (default: bugs/catalog.json)

require 'json'

BASE_DIR = File.expand_path('..', __dir__)

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------

results_dir = nil
catalog_path = File.join(BASE_DIR, 'bugs', 'catalog.json')

i = 0
while i < ARGV.length
  case ARGV[i]
  when '--results'
    results_dir = File.expand_path(ARGV[i + 1])
    i += 2
  when '--catalog'
    catalog_path = File.expand_path(ARGV[i + 1])
    i += 2
  else
    i += 1
  end
end

unless results_dir
  puts "Usage: ruby review/score.rb --results DIR [--catalog FILE]"
  exit 1
end

# ---------------------------------------------------------------------------
# Load data
# ---------------------------------------------------------------------------

catalog = JSON.parse(File.read(catalog_path))
bug_types = catalog['bugs'].map { |b| b['type'] }.uniq

# Load all review result files
review_files = Dir.glob(File.join(results_dir, 'trial-*.json')).sort
if review_files.empty?
  puts "ERROR: No review result files found in #{results_dir}"
  exit 1
end

puts "Scoring #{review_files.length} review results against #{catalog['bugs'].length} bug catalog entries"
puts

# ---------------------------------------------------------------------------
# Score each review
# ---------------------------------------------------------------------------

# Bug type keywords for fuzzy matching
BUG_TYPE_KEYWORDS = {
  'off-by-one'        => %w[off-by-one off by one obo boundary loop index iterate skip],
  'boundary-condition' => %w[boundary edge empty zero null none missing],
  'sort-order'         => %w[sort order reverse ascending descending],
  'hash-collision'     => %w[hash collision mask byte xor],
  'index-error'        => %w[index array element wrong entry],
  'silent-truncation'  => %w[truncat newline missing output format print],
  'state-leak'         => %w[state leak clear clean reset index],
}

def classify_bug_type(description)
  desc_lower = description.downcase
  BUG_TYPE_KEYWORDS.each do |type, keywords|
    return type if keywords.any? { |kw| desc_lower.include?(kw) }
  end
  'other'
end

def match_found_bug_to_injected(found_bug, injected_bugs)
  found_desc = (found_bug['description'] || '').downcase
  found_type = found_bug['bug_type'] || classify_bug_type(found_desc)

  # Try to match by bug type and description keywords
  injected_bugs.each do |inj|
    inj_desc = (inj['description'] || '').downcase
    inj_type = inj['type']

    # Direct type match
    type_match = found_type == inj_type

    # Keyword overlap in descriptions
    found_words = found_desc.split(/\W+/).reject { |w| w.length < 3 }
    inj_words = inj_desc.split(/\W+/).reject { |w| w.length < 3 }
    keyword_overlap = (found_words & inj_words).length

    if type_match && keyword_overlap >= 2
      return inj
    end
  end

  nil  # No match — false positive
end

scored_reviews = []

review_files.each do |file|
  review = JSON.parse(File.read(file))

  # Get injected bugs from the manifest embedded in the review
  injected = if review['manifest']
               review['manifest']['injected'] || []
             else
               []
             end

  found_bugs = review['bugs_found'] || []

  # Catalog entries for the injected bugs
  injected_catalog = injected.map do |inj|
    catalog['bugs'].find { |b| b['id'] == inj['id'] } || inj
  end

  # Match each found bug to an injected bug
  true_positives = []
  false_positives = []

  found_bugs.each do |found|
    matched = match_found_bug_to_injected(found, injected_catalog)
    if matched
      true_positives << { found: found, injected: matched }
    else
      false_positives << found
    end
  end

  # Bugs that were injected but not found
  detected_ids = true_positives.map { |tp| tp[:injected]['id'] }
  false_negatives = injected_catalog.reject { |inj| detected_ids.include?(inj['id']) }

  # Compute metrics
  tp = true_positives.length
  fp = false_positives.length
  fn = false_negatives.length

  precision = tp + fp > 0 ? tp.to_f / (tp + fp) : 0.0
  recall = tp + fn > 0 ? tp.to_f / (tp + fn) : 0.0
  f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0.0

  scored_reviews << {
    file: File.basename(file),
    condition: review['language'] || File.basename(file).split('-').last.sub('.json', ''),
    trial: review.dig('manifest', 'source_dir')&.match(/(\d+)-v2/)&.captures&.first&.to_i,
    injected_count: injected.length,
    found_count: found_bugs.length,
    true_positives: tp,
    false_positives: fp,
    false_negatives: fn,
    precision: precision.round(3),
    recall: recall.round(3),
    f1: f1.round(3),
    usage: review['usage'] || {},
    review_time_ms: review['review_time_ms'] || 0,
    tp_details: true_positives.map { |t| { found: t[:found]['bug_type'], injected: t[:injected]['id'] } },
    fp_details: false_positives.map { |f| { type: f['bug_type'], desc: f['description'] } },
    fn_details: false_negatives.map { |f| { id: f['id'], type: f['type'] } },
  }
end

# ---------------------------------------------------------------------------
# Aggregate by condition
# ---------------------------------------------------------------------------

by_condition = scored_reviews.group_by { |r| r[:condition] }

puts "=" * 70
puts "Scoring Results"
puts "=" * 70
puts

header = format('%-20s %6s %6s %6s %6s %8s %8s %8s',
                'Condition', 'TP', 'FP', 'FN', 'N', 'Prec', 'Recall', 'F1')
puts header
puts '-' * header.length

by_condition.sort.each do |condition, reviews|
  tp = reviews.sum { |r| r[:true_positives] }
  fp = reviews.sum { |r| r[:false_positives] }
  fn = reviews.sum { |r| r[:false_negatives] }
  n = reviews.length

  precision = tp + fp > 0 ? tp.to_f / (tp + fp) : 0.0
  recall = tp + fn > 0 ? tp.to_f / (tp + fn) : 0.0
  f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0.0

  puts format('%-20s %6d %6d %6d %6d %8.3f %8.3f %8.3f',
              condition, tp, fp, fn, n, precision, recall, f1)
end

# ---------------------------------------------------------------------------
# Token economics by condition
# ---------------------------------------------------------------------------

puts
puts "=" * 70
puts "Token Economics"
puts "=" * 70
puts

header = format('%-20s %10s %10s %10s %10s %8s',
                'Condition', 'InputTok', 'OutputTok', 'ThinkTok', 'Time(ms)', 'Cost$')
puts header
puts '-' * header.length

by_condition.sort.each do |condition, reviews|
  avg_input = reviews.sum { |r| r[:usage]['input_tokens'] || 0 }.to_f / reviews.length
  avg_output = reviews.sum { |r| r[:usage]['output_tokens'] || 0 }.to_f / reviews.length
  avg_thinking = reviews.sum { |r| r[:usage]['thinking_tokens'] || 0 }.to_f / reviews.length
  avg_time = reviews.sum { |r| r[:review_time_ms] }.to_f / reviews.length
  avg_cost = reviews.sum { |r| r[:usage]['total_cost_usd'] || 0.0 }.to_f / reviews.length

  puts format('%-20s %10.0f %10.0f %10.0f %10.0f %8.4f',
              condition, avg_input, avg_output, avg_thinking, avg_time, avg_cost)
end

# ---------------------------------------------------------------------------
# Detection by bug type
# ---------------------------------------------------------------------------

puts
puts "=" * 70
puts "Detection Rate by Bug Type"
puts "=" * 70
puts

all_tp = scored_reviews.flat_map { |r| r[:tp_details] }
all_fn = scored_reviews.flat_map { |r| r[:fn_details] }

bug_types.each do |type|
  tp_count = all_tp.count { |t| t[:injected]&.start_with?(type.split('-').first.upcase) rescue false }
  fn_count = all_fn.count { |f| f[:type] == type }
  total = tp_count + fn_count
  rate = total > 0 ? (tp_count.to_f / total * 100).round(1) : 0.0
  puts format("  %-25s %3d/%3d (%5.1f%%)", type, tp_count, total, rate)
end

# ---------------------------------------------------------------------------
# Save scored results
# ---------------------------------------------------------------------------

output_path = File.join(results_dir, 'scores.json')
File.write(output_path, JSON.pretty_generate({
  summary: by_condition.map { |cond, reviews|
    tp = reviews.sum { |r| r[:true_positives] }
    fp = reviews.sum { |r| r[:false_positives] }
    fn = reviews.sum { |r| r[:false_negatives] }
    precision = tp + fp > 0 ? tp.to_f / (tp + fp) : 0.0
    recall = tp + fn > 0 ? tp.to_f / (tp + fn) : 0.0
    f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0.0
    {
      condition: cond,
      reviews: reviews.length,
      true_positives: tp,
      false_positives: fp,
      false_negatives: fn,
      precision: precision.round(3),
      recall: recall.round(3),
      f1: f1.round(3),
    }
  },
  per_review: scored_reviews,
}))

puts
puts "Scores saved to #{output_path}"
