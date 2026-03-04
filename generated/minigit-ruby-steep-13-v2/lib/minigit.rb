# frozen_string_literal: true

module MiniGit
  MINIGIT_DIR = ".minigit"
  OBJECTS_DIR = "#{MINIGIT_DIR}/objects"
  COMMITS_DIR = "#{MINIGIT_DIR}/commits"
  INDEX_FILE  = "#{MINIGIT_DIR}/index"
  HEAD_FILE   = "#{MINIGIT_DIR}/HEAD"

  # @rbs (String) -> String
  def self.minihash(data)
    h = 1469598103934665603
    data.each_byte do |b|
      h ^= b
      h = (h * 1099511628211) % (2 ** 64)
    end
    format("%016x", h)
  end

  # @rbs () -> void
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

  # @rbs (String) -> void
  def self.cmd_add(filename)
    unless File.exist?(filename)
      $stderr.puts "File not found"
      exit 1
    end

    content = File.binread(filename)
    hash = minihash(content)
    File.binwrite("#{OBJECTS_DIR}/#{hash}", content)

    index_entries = read_index
    unless index_entries.include?(filename)
      index_entries << filename
      File.write(INDEX_FILE, index_entries.join("\n") + "\n")
    end
  end

  # @rbs (String) -> void
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
      hash = minihash(content)
      "#{f} #{hash}"
    end

    commit_content = "parent: #{parent}\ntimestamp: #{timestamp}\nmessage: #{message}\nfiles:\n#{file_lines.join("\n")}\n"
    commit_hash = minihash(commit_content)

    File.write("#{COMMITS_DIR}/#{commit_hash}", commit_content)
    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")

    puts "Committed #{commit_hash}"
  end

  # @rbs () -> void
  def self.cmd_status
    index_entries = read_index
    puts "Staged files:"
    if index_entries.empty?
      puts "(none)"
    else
      index_entries.each { |f| puts f }
    end
  end

  # @rbs () -> void
  def self.cmd_log
    head = File.read(HEAD_FILE).strip
    if head.empty?
      puts "No commits"
      return
    end

    current = head
    first = true
    while current && current != "NONE" && !current.empty?
      commit_path = "#{COMMITS_DIR}/#{current}"
      break unless File.exist?(commit_path)

      puts "" unless first
      first = false

      content = File.read(commit_path)
      timestamp = ""
      message = ""
      content.each_line do |line|
        line = line.chomp
        if line.start_with?("timestamp: ")
          timestamp = line.sub("timestamp: ", "")
        elsif line.start_with?("message: ")
          message = line.sub("message: ", "")
        end
      end

      puts "commit #{current}"
      puts "Date: #{timestamp}"
      puts "Message: #{message}"

      # Get parent
      parent_line = content.lines.first
      if parent_line
        current = parent_line.chomp.sub("parent: ", "")
      else
        break
      end
    end
  end

  # @rbs (String) -> Hash[String, String]
  def self.parse_commit_files(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      $stderr.puts "Invalid commit"
      exit 1
    end

    content = File.read(commit_path)
    files = {} #: Hash[String, String]
    in_files = false
    content.each_line do |line|
      line = line.chomp
      if line == "files:"
        in_files = true
      elsif in_files && !line.empty?
        parts = line.split(" ", 2)
        files[parts[0]] = parts[1] if parts.length == 2
      end
    end
    files
  end

  # @rbs (String, String) -> void
  def self.cmd_diff(commit1, commit2)
    files1 = parse_commit_files(commit1)
    files2 = parse_commit_files(commit2)

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

  # @rbs (String) -> void
  def self.cmd_checkout(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      $stderr.puts "Invalid commit"
      exit 1
    end

    files = parse_commit_files(commit_hash)
    files.each do |filename, blob_hash|
      blob_path = "#{OBJECTS_DIR}/#{blob_hash}"
      content = File.binread(blob_path)
      File.binwrite(filename, content)
    end

    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")

    puts "Checked out #{commit_hash}"
  end

  # @rbs (String) -> void
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

  # @rbs (String) -> void
  def self.cmd_rm(filename)
    index_entries = read_index
    unless index_entries.include?(filename)
      $stderr.puts "File not in index"
      exit 1
    end

    index_entries.delete(filename)
    if index_entries.empty?
      File.write(INDEX_FILE, "")
    else
      File.write(INDEX_FILE, index_entries.join("\n") + "\n")
    end
  end

  # @rbs (String) -> void
  def self.cmd_show(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      $stderr.puts "Invalid commit"
      exit 1
    end

    content = File.read(commit_path)
    timestamp = ""
    message = ""
    content.each_line do |line|
      line = line.chomp
      if line.start_with?("timestamp: ")
        timestamp = line.sub("timestamp: ", "")
      elsif line.start_with?("message: ")
        message = line.sub("message: ", "")
      end
    end

    files = parse_commit_files(commit_hash)

    puts "commit #{commit_hash}"
    puts "Date: #{timestamp}"
    puts "Message: #{message}"
    puts "Files:"
    files.keys.sort.each do |f|
      puts "  #{f} #{files[f]}"
    end
  end

  # @rbs () -> Array[String]
  def self.read_index
    return [] unless File.exist?(INDEX_FILE)
    content = File.read(INDEX_FILE).strip
    return [] if content.empty?
    content.split("\n")
  end

  # @rbs (Array[String]) -> void
  def self.run(args)
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
      c1 = args[1]
      c2 = args[2]
      if c1.nil? || c2.nil?
        $stderr.puts "Usage: minigit diff <commit1> <commit2>"
        exit 1
      end
      cmd_diff(c1, c2)
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
end
