# frozen_string_literal: true

module MiniGit
  MINIGIT_DIR = ".minigit"
  OBJECTS_DIR = "#{MINIGIT_DIR}/objects"
  COMMITS_DIR = "#{MINIGIT_DIR}/commits"
  INDEX_FILE  = "#{MINIGIT_DIR}/index"
  HEAD_FILE   = "#{MINIGIT_DIR}/HEAD"

  # MiniHash: FNV-1a variant, 64-bit, 16-char hex output
  def self.minihash(data)
    h = 1469598103934665603
    data.each_byte do |b|
      h = h ^ b
      h = (h * 1099511628211) % (2 ** 64)
    end
    format("%016x", h)
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
      filename = args[1]
      if filename.nil?
        $stderr.puts "Usage: minigit add <file>"
        exit 1
      end
      cmd_add(filename)
    when "commit"
      if args[1] == "-m" && args[2]
        cmd_commit(args[2])
      else
        $stderr.puts "Usage: minigit commit -m \"<message>\""
        exit 1
      end
    when "status"
      cmd_status
    when "log"
      cmd_log
    when "diff"
      if args[1] && args[2]
        cmd_diff(args[1], args[2])
      else
        $stderr.puts "Usage: minigit diff <commit1> <commit2>"
        exit 1
      end
    when "checkout"
      hash = args[1]
      if hash.nil?
        $stderr.puts "Usage: minigit checkout <commit_hash>"
        exit 1
      end
      cmd_checkout(hash)
    when "reset"
      hash = args[1]
      if hash.nil?
        $stderr.puts "Usage: minigit reset <commit_hash>"
        exit 1
      end
      cmd_reset(hash)
    when "rm"
      filename = args[1]
      if filename.nil?
        $stderr.puts "Usage: minigit rm <file>"
        exit 1
      end
      cmd_rm(filename)
    when "show"
      hash = args[1]
      if hash.nil?
        $stderr.puts "Usage: minigit show <commit_hash>"
        exit 1
      end
      cmd_show(hash)
    else
      $stderr.puts "Unknown command: #{command}"
      exit 1
    end
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
      puts "File not found"
      exit 1
    end

    content = File.binread(filename)
    hash = minihash(content)

    object_path = "#{OBJECTS_DIR}/#{hash}"
    File.binwrite(object_path, content)

    # Read current index entries
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject(&:empty?)

    unless entries.include?(filename)
      entries << filename
      File.write(INDEX_FILE, entries.join("\n") + "\n")
    end
  end

  def self.cmd_commit(message)
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject(&:empty?)

    if entries.empty?
      puts "Nothing to commit"
      exit 1
    end

    head_content = File.read(HEAD_FILE).strip
    parent = head_content.empty? ? "NONE" : head_content

    timestamp = Time.now.to_i

    sorted_files = entries.sort

    file_lines = sorted_files.map do |filename|
      content = File.binread(filename)
      blob_hash = minihash(content)
      "#{filename} #{blob_hash}"
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
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject(&:empty?)

    puts "Staged files:"
    if entries.empty?
      puts "(none)"
    else
      entries.each { |f| puts f }
    end
  end

  def self.parse_commit(hash)
    commit_path = "#{COMMITS_DIR}/#{hash}"
    unless File.exist?(commit_path)
      return nil
    end

    content = File.read(commit_path)
    lines = content.split("\n")

    parent = ""
    timestamp = ""
    message = ""
    files = {} #: Hash[String, String]
    in_files = false

    lines.each do |line|
      if in_files
        parts = line.split(" ", 2)
        if parts.length == 2
          files[parts[0]] = parts[1]
        end
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

    { "parent" => parent, "timestamp" => timestamp, "message" => message, "files" => files }
  end

  def self.cmd_diff(commit1, commit2)
    c1 = parse_commit(commit1)
    if c1.nil?
      puts "Invalid commit"
      exit 1
    end

    c2 = parse_commit(commit2)
    if c2.nil?
      puts "Invalid commit"
      exit 1
    end

    files1 = c1["files"] #: Hash[String, String]
    files2 = c2["files"] #: Hash[String, String]
    all_files = (files1.keys + files2.keys).uniq.sort

    all_files.each do |f|
      in1 = files1.key?(f)
      in2 = files2.key?(f)

      if in1 && in2
        if files1[f] != files2[f]
          puts "Modified: #{f}"
        end
      elsif in1 && !in2
        puts "Removed: #{f}"
      elsif !in1 && in2
        puts "Added: #{f}"
      end
    end
  end

  def self.cmd_checkout(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      puts "Invalid commit"
      exit 1
    end

    data = parse_commit(commit_hash)
    if data.nil?
      puts "Invalid commit"
      exit 1
    end

    files = data["files"] #: Hash[String, String]
    files.each do |filename, blob_hash|
      blob_path = "#{OBJECTS_DIR}/#{blob_hash}"
      content = File.binread(blob_path)
      File.binwrite(filename, content)
    end

    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")

    puts "Checked out #{commit_hash}"
  end

  def self.cmd_reset(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      puts "Invalid commit"
      exit 1
    end

    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")

    puts "Reset to #{commit_hash}"
  end

  def self.cmd_rm(filename)
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject(&:empty?)

    unless entries.include?(filename)
      puts "File not in index"
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
    data = parse_commit(commit_hash)
    if data.nil?
      puts "Invalid commit"
      exit 1
    end

    puts "commit #{commit_hash}"
    puts "Date: #{data["timestamp"]}"
    puts "Message: #{data["message"]}"
    puts "Files:"

    files = data["files"] #: Hash[String, String]
    files.keys.sort.each do |filename|
      puts "  #{filename} #{files[filename]}"
    end
  end

  def self.cmd_log
    head_content = File.read(HEAD_FILE).strip

    if head_content.empty?
      puts "No commits"
      return
    end

    current = head_content
    while current != "NONE" && !current.empty?
      commit_path = "#{COMMITS_DIR}/#{current}"
      break unless File.exist?(commit_path)

      content = File.read(commit_path)
      lines = content.split("\n")

      parent_line = ""
      timestamp_line = ""
      message_line = ""

      lines.each do |line|
        if line.start_with?("parent: ")
          parent_line = line.sub("parent: ", "")
        elsif line.start_with?("timestamp: ")
          timestamp_line = line.sub("timestamp: ", "")
        elsif line.start_with?("message: ")
          message_line = line.sub("message: ", "")
        end
      end

      puts "commit #{current}"
      puts "Date: #{timestamp_line}"
      puts "Message: #{message_line}"
      puts ""

      current = parent_line
    end
  end
end
