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

    index_entries = File.read(INDEX_FILE).split("\n").reject(&:empty?)
    unless index_entries.include?(filename)
      index_entries << filename
      File.write(INDEX_FILE, index_entries.join("\n") + "\n")
    end
  end

  # @rbs (String) -> void
  def self.cmd_commit(message)
    index_entries = File.read(INDEX_FILE).split("\n").reject(&:empty?)
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

    commit_content = "parent: #{parent}\ntimestamp: #{timestamp}\nmessage: #{message}\nfiles:\n#{file_lines.join("\n")}\n"

    commit_hash = minihash(commit_content)
    File.write("#{COMMITS_DIR}/#{commit_hash}", commit_content)
    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")
    puts "Committed #{commit_hash}"
  end

  # @rbs (String) -> Hash[String, String]
  def self.parse_commit(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    content = File.read(commit_path)
    lines = content.split("\n")

    result = { "parent" => "", "timestamp" => "", "message" => "" } #: Hash[String, String]
    in_files = false
    files = {} #: Hash[String, String]

    lines.each do |line|
      if in_files
        parts = line.split(" ")
        if parts.length == 2
          files[parts[0] || ""] = parts[1] || ""
        end
      elsif line.start_with?("parent: ")
        result["parent"] = line.sub("parent: ", "")
      elsif line.start_with?("timestamp: ")
        result["timestamp"] = line.sub("timestamp: ", "")
      elsif line.start_with?("message: ")
        result["message"] = line.sub("message: ", "")
      elsif line == "files:"
        in_files = true
      end
    end

    result["files_data"] = files.sort.map { |k, v| "#{k} #{v}" }.join("\n")
    result
  end

  # @rbs (String) -> Hash[String, String]
  def self.parse_commit_files(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    content = File.read(commit_path)
    lines = content.split("\n")

    in_files = false
    files = {} #: Hash[String, String]

    lines.each do |line|
      if in_files
        parts = line.split(" ")
        if parts.length == 2
          files[parts[0] || ""] = parts[1] || ""
        end
      elsif line == "files:"
        in_files = true
      end
    end

    files
  end

  # @rbs () -> void
  def self.cmd_status
    index_entries = File.read(INDEX_FILE).split("\n").reject(&:empty?)
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

    current = head #: String?
    while current && current != "NONE" && !current.empty?
      commit_path = "#{COMMITS_DIR}/#{current}"
      break unless File.exist?(commit_path)

      info = parse_commit(current)

      puts "commit #{current}"
      puts "Date: #{info["timestamp"]}"
      puts "Message: #{info["message"]}"
      puts ""

      current = info["parent"]
    end
  end

  # @rbs (String, String) -> void
  def self.cmd_diff(commit1, commit2)
    path1 = "#{COMMITS_DIR}/#{commit1}"
    path2 = "#{COMMITS_DIR}/#{commit2}"

    unless File.exist?(path1) && File.exist?(path2)
      $stderr.puts "Invalid commit"
      exit 1
    end

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
    index_entries = File.read(INDEX_FILE).split("\n").reject(&:empty?)
    unless index_entries.include?(filename)
      $stderr.puts "File not in index"
      exit 1
    end

    index_entries.delete(filename)
    File.write(INDEX_FILE, index_entries.empty? ? "" : index_entries.join("\n") + "\n")
  end

  # @rbs (String) -> void
  def self.cmd_show(commit_hash)
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"
    unless File.exist?(commit_path)
      $stderr.puts "Invalid commit"
      exit 1
    end

    info = parse_commit(commit_hash)
    files = parse_commit_files(commit_hash)

    puts "commit #{commit_hash}"
    puts "Date: #{info["timestamp"]}"
    puts "Message: #{info["message"]}"
    puts "Files:"
    files.sort.each do |filename, blob_hash|
      puts "  #{filename} #{blob_hash}"
    end
  end

  # @rbs (Array[String]) -> void
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
      cmd_add(args[1] || "")
    when "commit"
      if args.length < 3 || args[1] != "-m"
        $stderr.puts "Usage: minigit commit -m \"<message>\""
        exit 1
      end
      cmd_commit(args[2] || "")
    when "status"
      cmd_status
    when "log"
      cmd_log
    when "diff"
      if args.length < 3
        $stderr.puts "Usage: minigit diff <commit1> <commit2>"
        exit 1
      end
      cmd_diff(args[1] || "", args[2] || "")
    when "checkout"
      if args.length < 2
        $stderr.puts "Usage: minigit checkout <commit_hash>"
        exit 1
      end
      cmd_checkout(args[1] || "")
    when "reset"
      if args.length < 2
        $stderr.puts "Usage: minigit reset <commit_hash>"
        exit 1
      end
      cmd_reset(args[1] || "")
    when "rm"
      if args.length < 2
        $stderr.puts "Usage: minigit rm <file>"
        exit 1
      end
      cmd_rm(args[1] || "")
    when "show"
      if args.length < 2
        $stderr.puts "Usage: minigit show <commit_hash>"
        exit 1
      end
      cmd_show(args[1] || "")
    else
      $stderr.puts "Unknown command: #{command}"
      exit 1
    end
  end
end

if __FILE__ == $0
  MiniGit.run(ARGV)
end
