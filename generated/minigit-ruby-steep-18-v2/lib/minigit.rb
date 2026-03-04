# frozen_string_literal: true

module MiniGit
  MINIGIT_DIR = ".minigit"
  OBJECTS_DIR = "#{MINIGIT_DIR}/objects"
  COMMITS_DIR = "#{MINIGIT_DIR}/commits"
  INDEX_FILE  = "#{MINIGIT_DIR}/index"
  HEAD_FILE   = "#{MINIGIT_DIR}/HEAD"

  # @rbs data: String
  # @rbs return: String
  def self.minihash(data)
    h = 1469598103934665603
    data.each_byte do |b|
      h ^= b
      h = (h * 1099511628211) % (2 ** 64)
    end
    format("%016x", h)
  end

  # @rbs args: Array[String]
  # @rbs return: void
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

  # @rbs return: void
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

  # @rbs filename: String
  # @rbs return: void
  def self.cmd_add(filename)
    unless File.exist?(filename)
      puts "File not found"
      exit 1
    end

    content = File.binread(filename)
    hash = minihash(content)
    object_path = "#{OBJECTS_DIR}/#{hash}"

    File.binwrite(object_path, content) unless File.exist?(object_path)

    index_entries = read_index
    unless index_entries.include?(filename)
      index_entries << filename
      write_index(index_entries)
    end
  end

  # @rbs message: String
  # @rbs return: void
  def self.cmd_commit(message)
    index_entries = read_index
    if index_entries.empty?
      puts "Nothing to commit"
      exit 1
    end

    parent = read_head
    parent_str = parent.empty? ? "NONE" : parent
    timestamp = Time.now.to_i

    sorted_files = index_entries.sort

    file_lines = sorted_files.map do |filename|
      content = File.binread(filename)
      hash = minihash(content)
      "#{filename} #{hash}"
    end

    commit_content = "parent: #{parent_str}\n"
    commit_content += "timestamp: #{timestamp}\n"
    commit_content += "message: #{message}\n"
    commit_content += "files:\n"
    commit_content += file_lines.join("\n") + "\n"

    commit_hash = minihash(commit_content)

    File.write("#{COMMITS_DIR}/#{commit_hash}", commit_content)
    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")

    puts "Committed #{commit_hash}"
  end

  # @rbs return: void
  def self.cmd_log
    head = read_head
    if head.empty?
      puts "No commits"
      return
    end

    current = head
    while current && !current.empty?
      commit_path = "#{COMMITS_DIR}/#{current}"
      unless File.exist?(commit_path)
        break
      end

      content = File.read(commit_path)
      lines = content.split("\n")

      timestamp = ""
      message = ""
      parent = ""

      lines.each do |line|
        if line.start_with?("timestamp: ")
          timestamp = line.sub("timestamp: ", "")
        elsif line.start_with?("message: ")
          message = line.sub("message: ", "")
        elsif line.start_with?("parent: ")
          parent = line.sub("parent: ", "")
        end
      end

      puts "commit #{current}"
      puts "Date: #{timestamp}"
      puts "Message: #{message}"
      puts ""

      current = parent == "NONE" ? "" : parent
    end
  end

  # @rbs return: void
  def self.cmd_status
    entries = read_index
    puts "Staged files:"
    if entries.empty?
      puts "(none)"
    else
      entries.each { |f| puts f }
    end
  end

  # @rbs commit1: String
  # @rbs commit2: String
  # @rbs return: void
  def self.cmd_diff(commit1, commit2)
    path1 = "#{COMMITS_DIR}/#{commit1}"
    path2 = "#{COMMITS_DIR}/#{commit2}"

    unless File.exist?(path1) && File.exist?(path2)
      puts "Invalid commit"
      exit 1
    end

    files1 = parse_commit_files(File.read(path1))
    files2 = parse_commit_files(File.read(path2))

    all_files = (files1.keys + files2.keys).uniq.sort

    all_files.each do |filename|
      in1 = files1.key?(filename)
      in2 = files2.key?(filename)

      if in1 && !in2
        puts "Removed: #{filename}"
      elsif !in1 && in2
        puts "Added: #{filename}"
      elsif in1 && in2 && files1[filename] != files2[filename]
        puts "Modified: #{filename}"
      end
    end
  end

  # @rbs hash: String
  # @rbs return: void
  def self.cmd_checkout(hash)
    commit_path = "#{COMMITS_DIR}/#{hash}"
    unless File.exist?(commit_path)
      puts "Invalid commit"
      exit 1
    end

    content = File.read(commit_path)
    files = parse_commit_files(content)

    files.each do |filename, blob_hash|
      blob_path = "#{OBJECTS_DIR}/#{blob_hash}"
      blob_content = File.binread(blob_path)
      File.binwrite(filename, blob_content)
    end

    File.write(HEAD_FILE, hash)
    File.write(INDEX_FILE, "")

    puts "Checked out #{hash}"
  end

  # @rbs hash: String
  # @rbs return: void
  def self.cmd_reset(hash)
    commit_path = "#{COMMITS_DIR}/#{hash}"
    unless File.exist?(commit_path)
      puts "Invalid commit"
      exit 1
    end

    File.write(HEAD_FILE, hash)
    File.write(INDEX_FILE, "")

    puts "Reset to #{hash}"
  end

  # @rbs filename: String
  # @rbs return: void
  def self.cmd_rm(filename)
    entries = read_index
    unless entries.include?(filename)
      puts "File not in index"
      exit 1
    end

    entries.delete(filename)
    if entries.empty?
      File.write(INDEX_FILE, "")
    else
      write_index(entries)
    end
  end

  # @rbs hash: String
  # @rbs return: void
  def self.cmd_show(hash)
    commit_path = "#{COMMITS_DIR}/#{hash}"
    unless File.exist?(commit_path)
      puts "Invalid commit"
      exit 1
    end

    content = File.read(commit_path)
    lines = content.split("\n")

    timestamp = ""
    message = ""

    lines.each do |line|
      if line.start_with?("timestamp: ")
        timestamp = line.sub("timestamp: ", "")
      elsif line.start_with?("message: ")
        message = line.sub("message: ", "")
      end
    end

    files = parse_commit_files(content)

    puts "commit #{hash}"
    puts "Date: #{timestamp}"
    puts "Message: #{message}"
    puts "Files:"
    files.keys.sort.each do |filename|
      puts "  #{filename} #{files[filename]}"
    end
  end

  # @rbs content: String
  # @rbs return: Hash[String, String]
  def self.parse_commit_files(content)
    files = {} #: Hash[String, String]
    in_files = false
    content.split("\n").each do |line|
      if line == "files:"
        in_files = true
        next
      end
      if in_files && !line.empty?
        parts = line.split(" ", 2)
        files[parts[0]] = parts[1] if parts.length == 2 && parts[0] && parts[1]
      end
    end
    files
  end

  # @rbs return: Array[String]
  def self.read_index
    return [] unless File.exist?(INDEX_FILE)
    content = File.read(INDEX_FILE).strip
    return [] if content.empty?
    content.split("\n")
  end

  # @rbs entries: Array[String]
  # @rbs return: void
  def self.write_index(entries)
    File.write(INDEX_FILE, entries.join("\n") + "\n")
  end

  # @rbs return: String
  def self.read_head
    return "" unless File.exist?(HEAD_FILE)
    File.read(HEAD_FILE).strip
  end
end
