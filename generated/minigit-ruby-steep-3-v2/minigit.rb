# frozen_string_literal: true

module MiniGit
  MINIGIT_DIR = ".minigit"
  OBJECTS_DIR = "#{MINIGIT_DIR}/objects"
  COMMITS_DIR = "#{MINIGIT_DIR}/commits"
  INDEX_FILE  = "#{MINIGIT_DIR}/index"
  HEAD_FILE   = "#{MINIGIT_DIR}/HEAD"

  FNV_OFFSET = 1469598103934665603
  FNV_PRIME  = 1099511628211
  MOD64      = 2 ** 64

  def self.minihash(data)
    h = FNV_OFFSET
    data.each_byte do |b|
      h ^= b
      h = (h * FNV_PRIME) % MOD64
    end
    format("%016x", h)
  end

  def self.cmd_init
    if Dir.exist?(MINIGIT_DIR)
      puts "Repository already initialized"
      return
    end
    Dir.mkdir(MINIGIT_DIR)
    Dir.mkdir(OBJECTS_DIR)
    Dir.mkdir(COMMITS_DIR)
    File.write(INDEX_FILE, "")
    File.write(HEAD_FILE, "")
  end

  def self.cmd_add(filename)
    unless File.exist?(filename)
      $stderr.puts "File not found"
      exit 1
    end

    content = File.binread(filename)
    hash = minihash(content)
    object_path = "#{OBJECTS_DIR}/#{hash}"
    File.binwrite(object_path, content)

    index_entries = read_index
    unless index_entries.include?(filename)
      index_entries << filename
      File.write(INDEX_FILE, index_entries.join("\n") + "\n")
    end
  end

  def self.cmd_commit(message)
    index_entries = read_index
    if index_entries.empty?
      $stderr.puts "Nothing to commit"
      exit 1
    end

    parent = File.read(HEAD_FILE).strip
    parent = "NONE" if parent.empty?
    timestamp = Time.now.to_i

    sorted_files = index_entries.sort
    file_lines = sorted_files.map do |f|
      content = File.binread(f)
      blob_hash = minihash(content)
      "#{f} #{blob_hash}"
    end

    commit_content = "parent: #{parent}\n" \
                     "timestamp: #{timestamp}\n" \
                     "message: #{message}\n" \
                     "files:\n" \
                     "#{file_lines.join("\n")}\n"

    commit_hash = minihash(commit_content)
    File.write("#{COMMITS_DIR}/#{commit_hash}", commit_content)
    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")

    puts "Committed #{commit_hash}"
  end

  def self.cmd_status
    entries = read_index
    puts "Staged files:"
    if entries.empty?
      puts "(none)"
    else
      entries.each { |f| puts f }
    end
  end

  def self.cmd_log
    head = File.read(HEAD_FILE).strip
    if head.empty?
      puts "No commits"
      return
    end

    current = head
    while current != "NONE" && !current.empty?
      commit_path = "#{COMMITS_DIR}/#{current}"
      break unless File.exist?(commit_path)

      parsed = parse_commit(File.read(commit_path))

      puts "commit #{current}"
      puts "Date: #{parsed[:timestamp]}"
      puts "Message: #{parsed[:message]}"
      puts ""

      current = parsed[:parent]
    end
  end

  def self.parse_commit(content)
    lines = content.split("\n")
    parent = ""
    timestamp = ""
    message = ""
    files = {} #: Hash[String, String]
    in_files = false

    lines.each do |line|
      if in_files
        parts = line.split(" ", 2)
        files[parts[0]] = parts[1] if parts.length == 2
      elsif line.start_with?("parent: ")
        parent = line.sub("parent: ", "")
      elsif line.start_with?("timestamp: ")
        timestamp = line.sub("timestamp: ", "")
      elsif line.start_with?("message: ")
        message = line.sub("message: ", "")
      elsif line == "files:"
        in_files = true
      end
    end

    { parent: parent, timestamp: timestamp, message: message, files: files }
  end

  def self.cmd_diff(hash1, hash2)
    path1 = "#{COMMITS_DIR}/#{hash1}"
    path2 = "#{COMMITS_DIR}/#{hash2}"

    unless File.exist?(path1) && File.exist?(path2)
      $stderr.puts "Invalid commit"
      exit 1
    end

    files1 = parse_commit(File.read(path1))[:files]
    files2 = parse_commit(File.read(path2))[:files]

    all_files = (files1.keys + files2.keys).uniq.sort

    all_files.each do |f|
      if files1.key?(f) && files2.key?(f)
        puts "Modified: #{f}" if files1[f] != files2[f]
      elsif files2.key?(f)
        puts "Added: #{f}"
      else
        puts "Removed: #{f}"
      end
    end
  end

  def self.cmd_checkout(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      $stderr.puts "Invalid commit"
      exit 1
    end

    parsed = parse_commit(File.read(commit_path))
    parsed[:files].each do |filename, blob_hash|
      blob_path = "#{OBJECTS_DIR}/#{blob_hash}"
      File.binwrite(filename, File.binread(blob_path))
    end

    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")
    puts "Checked out #{commit_hash}"
  end

  def self.cmd_reset(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      $stderr.puts "Invalid commit"
      exit 1
    end

    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")
    puts "Reset to #{commit_hash}"
  end

  def self.cmd_rm(filename)
    entries = read_index
    unless entries.include?(filename)
      $stderr.puts "File not in index"
      exit 1
    end

    entries.delete(filename)
    if entries.empty?
      File.write(INDEX_FILE, "")
    else
      File.write(INDEX_FILE, entries.join("\n") + "\n")
    end
  end

  def self.cmd_show(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      $stderr.puts "Invalid commit"
      exit 1
    end

    parsed = parse_commit(File.read(commit_path))
    puts "commit #{commit_hash}"
    puts "Date: #{parsed[:timestamp]}"
    puts "Message: #{parsed[:message]}"
    puts "Files:"
    parsed[:files].keys.sort.each do |f|
      puts "  #{f} #{parsed[:files][f]}"
    end
  end

  def self.read_index
    return [] unless File.exist?(INDEX_FILE)
    content = File.read(INDEX_FILE).strip
    return [] if content.empty?
    content.split("\n")
  end

  def self.run(args)
    if args.empty?
      $stderr.puts "Usage: minigit <command>"
      exit 1
    end

    command = args[0]

    case command
    when "init"
      cmd_init
    when "add"
      if args.length < 2
        $stderr.puts "Usage: minigit add <file>"
        exit 1
      end
      cmd_add(args[1]) #: nil
    when "commit"
      if args.length < 3 || args[1] != "-m"
        $stderr.puts "Usage: minigit commit -m \"<message>\""
        exit 1
      end
      cmd_commit(args[2]) #: nil
    when "status"
      cmd_status
    when "log"
      cmd_log
    when "diff"
      if args.length < 3
        $stderr.puts "Usage: minigit diff <commit1> <commit2>"
        exit 1
      end
      cmd_diff(args[1], args[2]) #: nil
    when "checkout"
      if args.length < 2
        $stderr.puts "Usage: minigit checkout <commit_hash>"
        exit 1
      end
      cmd_checkout(args[1]) #: nil
    when "reset"
      if args.length < 2
        $stderr.puts "Usage: minigit reset <commit_hash>"
        exit 1
      end
      cmd_reset(args[1]) #: nil
    when "rm"
      if args.length < 2
        $stderr.puts "Usage: minigit rm <file>"
        exit 1
      end
      cmd_rm(args[1]) #: nil
    when "show"
      if args.length < 2
        $stderr.puts "Usage: minigit show <commit_hash>"
        exit 1
      end
      cmd_show(args[1]) #: nil
    else
      $stderr.puts "Unknown command: #{command}"
      exit 1
    end
  end
end
