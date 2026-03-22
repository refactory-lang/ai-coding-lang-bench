#!/usr/bin/env ruby
# frozen_string_literal: true

# Bug injection script for Track 1 experiments (A and B).
#
# Injects seeded logic bugs from catalog.json into MiniGit implementations.
# Each bug is designed to pass the existing test suite but be logically wrong
# on untested paths.
#
# Usage:
#   ruby bugs/inject.rb --source DIR --lang LANG [--count N] [--seed S] [--catalog FILE]
#
# Options:
#   --source DIR      Source directory containing a MiniGit implementation
#   --lang LANG       Language of the implementation (python, rust)
#   --count N         Number of bugs to inject (default: 4, range: 3-5)
#   --seed S          Random seed for reproducible bug selection
#   --catalog FILE    Path to bug catalog (default: bugs/catalog.json)
#   --output DIR      Output directory (default: SOURCE-bugged)
#   --dry-run         Show which bugs would be injected without modifying files

require 'json'
require 'fileutils'

BASE_DIR = File.expand_path('..', __dir__)

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------

source_dir = nil
lang = nil
count = 4
seed = nil
catalog_path = File.join(BASE_DIR, 'bugs', 'catalog.json')
output_dir = nil
dry_run = false

i = 0
while i < ARGV.length
  case ARGV[i]
  when '--source'
    source_dir = File.expand_path(ARGV[i + 1])
    i += 2
  when '--lang'
    lang = ARGV[i + 1]
    i += 2
  when '--count'
    count = ARGV[i + 1].to_i
    i += 2
  when '--seed'
    seed = ARGV[i + 1].to_i
    i += 2
  when '--catalog'
    catalog_path = File.expand_path(ARGV[i + 1])
    i += 2
  when '--output'
    output_dir = File.expand_path(ARGV[i + 1])
    i += 2
  when '--dry-run'
    dry_run = true
    i += 1
  else
    i += 1
  end
end

unless source_dir && lang
  puts "Usage: ruby bugs/inject.rb --source DIR --lang LANG [--count N] [--seed S]"
  exit 1
end

unless File.exist?(catalog_path)
  puts "ERROR: Bug catalog not found: #{catalog_path}"
  exit 1
end

unless File.directory?(source_dir)
  puts "ERROR: Source directory not found: #{source_dir}"
  exit 1
end

output_dir ||= "#{source_dir}-bugged"
count = count.clamp(3, 5)
rng = seed ? Random.new(seed) : Random.new

# ---------------------------------------------------------------------------
# Load catalog and select bugs
# ---------------------------------------------------------------------------

catalog = JSON.parse(File.read(catalog_path))
available_bugs = catalog['bugs'].select { |b| b['languages'].include?(lang) }

if available_bugs.length < count
  puts "WARNING: Only #{available_bugs.length} bugs available for #{lang}, requested #{count}"
  count = available_bugs.length
end

selected_bugs = available_bugs.shuffle(random: rng).first(count)

puts "Bug injection plan:"
puts "  Source: #{source_dir}"
puts "  Language: #{lang}"
puts "  Output: #{output_dir}"
puts "  Bugs to inject (#{selected_bugs.length}):"
selected_bugs.each do |bug|
  puts "    #{bug['id']}: #{bug['description']} (difficulty: #{bug['difficulty']})"
end
puts

if dry_run
  puts "[DRY RUN] No files modified."
  exit 0
end

# ---------------------------------------------------------------------------
# Copy source to output
# ---------------------------------------------------------------------------

FileUtils.rm_rf(output_dir)
FileUtils.cp_r(source_dir, output_dir)

# ---------------------------------------------------------------------------
# Bug injection patterns
# ---------------------------------------------------------------------------

# Find source files by language
def find_source_files(dir, lang)
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

  # Also check the minigit executable itself (may be a script without extension)
  minigit = File.join(dir, 'minigit')
  if File.exist?(minigit) && !files.include?(minigit)
    content = File.read(minigit, encoding: 'UTF-8') rescue nil
    files << minigit if content&.valid_encoding?
  end

  files
end

# Try to inject a bug into any source file. Returns true if successful.
def inject_bug(files, bug_id, lang)
  case bug_id
  when 'OBO-001' then inject_obo_001(files, lang)
  when 'OBO-002' then inject_obo_002(files, lang)
  when 'BC-001'  then inject_bc_001(files, lang)
  when 'BC-002'  then inject_bc_002(files, lang)
  when 'SO-001'  then inject_so_001(files, lang)
  when 'HC-001'  then inject_hc_001(files, lang)
  when 'IE-001'  then inject_ie_001(files, lang)
  when 'ST-001'  then inject_st_001(files, lang)
  when 'SL-001'  then inject_sl_001(files, lang)
  when 'BC-003'  then inject_bc_003(files, lang)
  else
    puts "  WARNING: No injection logic for #{bug_id}"
    false
  end
end

# Helper: find a file containing a pattern, replace first match
def find_and_replace(files, pattern, replacement)
  files.each do |f|
    content = File.read(f, encoding: 'UTF-8') rescue next
    if content.match?(pattern)
      new_content = content.sub(pattern, replacement)
      if new_content != content
        File.write(f, new_content)
        return { file: f, pattern: pattern.source }
      end
    end
  end
  nil
end

# OBO-001: Off-by-one in commit log traversal
def inject_obo_001(files, lang)
  case lang
  when 'python'
    # Add an early-exit condition that skips the last commit in the chain
    # Look for the log traversal loop and add a break-before-last
    result = find_and_replace(files,
      /while\s+(\w+)\s*(?:!=|is not)\s*["']NONE["']/,
      'while \1 != "NONE" and \1 != ""')
    # Alternative: look for parent reading pattern and skip one level
    result ||= find_and_replace(files,
      /(parent\s*=.*\n)(.*?)(if\s+parent|while\s+parent|current\s*=\s*parent)/m,
      "\\1\\2# BUG: skip if parent is the root commit\n    if parent == 'NONE' or parent == '':\n        break\n    \\3")
    result
  when 'rust'
    # Add early termination in the log loop
    find_and_replace(files,
      /(while\s+\w+\s*!=\s*"NONE")/,
      '\\1 && current != ""')
  end
end

# OBO-002: Off-by-one in diff line numbering
def inject_obo_002(files, lang)
  case lang
  when 'python'
    # Change 1-based to 0-based line numbering in diff output, or
    # swap >= to > in a comparison
    result = find_and_replace(files,
      /("Added:\s*")\s*\+\s*(\w+)/,
      '"Added: " + \\2')
    # If that didn't work, try to find diff comparison and weaken it
    result ||= find_and_replace(files,
      /(for\s+\w+\s+in\s+\w+(?:_files|_list|1))\s*:/,
      '\\1:  # BUG: iterating over wrong set')
    result
  when 'rust'
    find_and_replace(files,
      /(println!\("Added:\s*\{)/,
      'println!("Added: {')
  end
end

# BC-001: Empty file handling — hash returns wrong value for zero-length content
def inject_bc_001(files, lang)
  case lang
  when 'python'
    # Add an early return for empty content in the hash function
    result = find_and_replace(files,
      /(def\s+\w*hash\w*\(.*?\).*?:)\s*\n(\s+)/m,
      "\\1\n\\2# BUG: wrong result for empty input\n\\2if not \\3 if len(data) == 0 if hasattr(data, '__len__') else False else False:\n\\2    return '0' * 16\n\\2")
    # Simpler approach: find the hash init and add an early return
    result ||= find_and_replace(files,
      /(h\s*=\s*1469598103934665603)/,
      "\\1\n    if len(data) == 0:\n        return '0' * 16  # BUG: wrong hash for empty content")
    result
  when 'rust'
    find_and_replace(files,
      /(let\s+mut\s+h\s*:\s*u64\s*=\s*1469598103934665603)/,
      "if data.is_empty() { return \"0\".repeat(16); } // BUG: wrong hash for empty\n    \\1")
  end
end

# BC-002: Missing directory creation for subdirectory files in add
def inject_bc_002(files, lang)
  case lang
  when 'python'
    # Find where objects are written and remove parent dir creation
    result = find_and_replace(files,
      /(os\.makedirs.*?objects.*?exist_ok\s*=\s*True\s*\))/,
      '# BUG: removed makedirs for object subdirectory\n    # \\1')
    # Alternative: find the write_file / open call for objects and don't create parent
    result ||= find_and_replace(files,
      /(Path.*?objects.*?parent.*?mkdir)/,
      '# BUG: skipped parent mkdir\n    # \\1')
    result
  when 'rust'
    find_and_replace(files,
      /(create_dir_all.*?objects)/,
      '// BUG: skipped create_dir_all for objects\n    // \\1')
  end
end

# SO-001: Reversed sort in status output
def inject_so_001(files, lang)
  case lang
  when 'python'
    # Find sorted() call in status and reverse it
    result = find_and_replace(files,
      /(sorted\(.*?\))/,
      '\\1[::-1]  # BUG: reversed sort')
    # Alternative: find .sort() call and add reverse=True
    result ||= find_and_replace(files,
      /(\.sort\(\))/,
      '.sort(reverse=True)  # BUG: reversed sort')
    result
  when 'rust'
    # Find .sort() call and change to .sort_by(|a, b| b.cmp(a))
    find_and_replace(files,
      /(\.sort\(\);\s*)(.*?status|.*?staged|.*?index)/m,
      '.sort_by(|a, b| b.cmp(a)); // BUG: reversed sort\n    \\2')
  end
end

# HC-001: Incorrect byte masking in MiniHash
def inject_hc_001(files, lang)
  case lang
  when 'python'
    # Add a mask before XOR that only affects bytes > 127
    result = find_and_replace(files,
      /(h\s*\^=\s*b\b)/,
      'h ^= (b & 0x7F)  # BUG: masks high bit, wrong for non-ASCII')
    # Alternative pattern
    result ||= find_and_replace(files,
      /(h\s*=\s*h\s*\^\s*b\b)/,
      'h = h ^ (b & 0x7F)  # BUG: masks high bit')
    result
  when 'rust'
    result = find_and_replace(files,
      /(h\s*\^=\s*\*?b\s+as\s+u64)/,
      'h ^= (*b & 0x7F) as u64 // BUG: masks high bit')
    result ||= find_and_replace(files,
      /(h\s*\^=\s*(\w+)\s+as\s+u64)/,
      'h ^= (\\2 & 0x7F) as u64 // BUG: masks high bit')
    result
  end
end

# IE-001: Wrong index when reading staged files during commit
def inject_ie_001(files, lang)
  case lang
  when 'python'
    # Find where index entries are iterated during commit and add an off-by-one
    result = find_and_replace(files,
      /(for\s+\w+\s+in\s+(?:staged|index|files|entries).*?:.*?\n\s+)(.*?hash|.*?blob)/m,
      "\\1# BUG: processes files but could duplicate last entry\n    \\2")
    result
  when 'rust'
    find_and_replace(files,
      /(for\s+\w+\s+in\s+(?:staged|index|files|entries))/,
      '\\1 // BUG: iteration order may not match')
  end
end

# ST-001: Missing trailing newline in show command output
def inject_st_001(files, lang)
  case lang
  when 'python'
    # Find the show command's print/write for file content and strip trailing newline
    result = find_and_replace(files,
      /(print\(f?"?\s*Files:)/,
      'print("Files:", end="")  # BUG: missing newline after Files:')
    # Alternative: find the two-space indent output and remove it
    result ||= find_and_replace(files,
      /(print\(f?\s*["']\s\s)/,
      'print(f" ')  # BUG: single space indent instead of two')
    result
  when 'rust'
    find_and_replace(files,
      /(println!\("Files:)/,
      'print!("Files:')  # BUG: print instead of println')
  end
end

# SL-001: Incomplete index cleanup after reset
def inject_sl_001(files, lang)
  case lang
  when 'python'
    # Find reset's index clearing and make it a no-op
    result = find_and_replace(files,
      /(["']reset["'].*?)(open\(.*?index.*?["']w["']\).*?write\(["']['"]?\))/m,
      '\\1pass  # BUG: index not actually cleared\n    # \\2')
    # Alternative: find the index truncation in reset
    result ||= find_and_replace(files,
      /(def\s+\w*reset.*?)(index_path|index_file)(.*?)(\.write_text\(["']["']\)|open.*?["']w["'])/m,
      '\\1\\2\\3pass  # BUG: index write removed in reset')
    result
  when 'rust'
    find_and_replace(files,
      /(reset.*?)(write\(.*?index.*?"")/m,
      '\\1// BUG: index not cleared\n    // \\2')
  end
end

# BC-003: Checkout silently overwrites uncommitted changes
def inject_bc_003(files, lang)
  # This is actually the inverse — the bug is that checkout does NOT check
  # for uncommitted changes. Most implementations already don't check.
  # For the injection, we need to find one that DOES check and remove the check.
  # If none check, this bug already exists and we report it as "naturally present."
  case lang
  when 'python'
    result = find_and_replace(files,
      /(#.*?uncommitted|#.*?dirty|#.*?modified.*?check)/i,
      '# BUG: check for uncommitted changes removed')
    # If the check didn't exist, this bug is inherent in the implementation
    result || { file: 'N/A', pattern: 'checkout-no-dirty-check (naturally present)' }
  when 'rust'
    result = find_and_replace(files,
      /(\/\/.*?uncommitted|\/\/.*?dirty|\/\/.*?modified.*?check)/i,
      '// BUG: check for uncommitted changes removed')
    result || { file: 'N/A', pattern: 'checkout-no-dirty-check (naturally present)' }
  end
end

# ---------------------------------------------------------------------------
# Inject bugs
# ---------------------------------------------------------------------------

source_files = find_source_files(output_dir, lang)

if source_files.empty?
  puts "ERROR: No source files found in #{output_dir} for language #{lang}"
  exit 1
end

puts "Found #{source_files.length} source file(s)"
puts

injected = []
failed = []

selected_bugs.each do |bug|
  print "Injecting #{bug['id']}... "
  result = inject_bug(source_files, bug['id'], lang)
  if result
    puts "OK (#{result[:file]})"
    injected << { bug: bug, result: result }
  else
    puts "SKIPPED (pattern not found)"
    failed << bug
  end
end

# ---------------------------------------------------------------------------
# Write injection manifest
# ---------------------------------------------------------------------------

manifest = {
  source_dir: source_dir,
  output_dir: output_dir,
  language: lang,
  seed: seed,
  injected: injected.map { |i| { id: i[:bug]['id'], type: i[:bug]['type'], difficulty: i[:bug]['difficulty'], file: i[:result][:file] } },
  skipped: failed.map { |b| { id: b['id'], reason: 'pattern not found' } },
}

manifest_path = File.join(output_dir, '.bug-manifest.json')
File.write(manifest_path, JSON.pretty_generate(manifest))

puts
puts "Injection complete:"
puts "  Injected: #{injected.length}"
puts "  Skipped:  #{failed.length}"
puts "  Manifest: #{manifest_path}"
puts
puts "Run 'bash bugs/verify_stealth.sh #{output_dir}' to verify bugs pass tests."
