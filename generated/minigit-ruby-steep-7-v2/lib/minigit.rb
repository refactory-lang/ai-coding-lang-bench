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
      cmd_add(args[1])
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
      if args[1]
        cmd_checkout(args[1])
      else
        $stderr.puts "Usage: minigit checkout <commit_hash>"
        exit 1
      end
    when "reset"
      if args[1]
        cmd_reset(args[1])
      else
        $stderr.puts "Usage: minigit reset <commit_hash>"
        exit 1
      end
    when "rm"
      if args[1]
        cmd_rm(args[1])
      else
        $stderr.puts "Usage: minigit rm <file>"
        exit 1
      end
    when "show"
      if args[1]
        cmd_show(args[1])
      else
        $stderr.puts "Usage: minigit show <commit_hash>"
        exit 1
      end
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
    if filename.nil?
      $stderr.puts "Usage: minigit add <file>"
      exit 1
    end

    unless File.exist?(filename)
      puts "File not found"
      exit 1
    end

    content = File.binread(filename)
    hash = minihash(content)

    blob_path = "#{OBJECTS_DIR}/#{hash}"
    File.binwrite(blob_path, content)

    # Read current index entries
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject { |line| line.empty? }

    unless entries.include?(filename)
      entries << filename
      File.write(INDEX_FILE, entries.join("\n") + "\n")
    end
  end

  def self.cmd_commit(message)
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject { |line| line.empty? }

    if entries.empty?
      puts "Nothing to commit"
      exit 1
    end

    head = File.read(HEAD_FILE).strip
    parent = head.empty? ? "NONE" : head
    timestamp = Time.now.to_i

    sorted_files = entries.sort

    file_lines = sorted_files.map do |filename|
      content = File.binread(filename)
      blob_hash = minihash(content)
      "#{filename} #{blob_hash}"
    end

    commit_content = "parent: #{parent}\ntimestamp: #{timestamp}\nmessage: #{message}\nfiles:\n#{file_lines.join("\n")}\n"

    commit_hash = minihash(commit_content)

    File.write("#{COMMITS_DIR}/#{commit_hash}", commit_content)
    File.write(HEAD_FILE, commit_hash)
    File.write(INDEX_FILE, "")

    puts "Committed #{commit_hash}"
  end

  def self.cmd_status
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject { |line| line.empty? }

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
      commit_content = File.read(commit_path)

      timestamp = ""
      message = ""
      commit_content.each_line do |line|
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
      puts ""

      # Find parent
      parent = "NONE"
      commit_content.each_line do |line|
        line = line.chomp
        if line.start_with?("parent: ")
          parent = line.sub("parent: ", "")
          break
        end
      end

      current = parent
    end
  end

  def self.parse_commit_files(commit_content)
    files = {} #: Hash[String, String]
    in_files = false
    commit_content.each_line do |line|
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

  def self.cmd_diff(commit1, commit2)
    commit1_path = "#{COMMITS_DIR}/#{commit1}"
    commit2_path = "#{COMMITS_DIR}/#{commit2}"

    unless File.exist?(commit1_path) && File.exist?(commit2_path)
      puts "Invalid commit"
      exit 1
    end

    files1 = parse_commit_files(File.read(commit1_path))
    files2 = parse_commit_files(File.read(commit2_path))

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
      puts "Invalid commit"
      exit 1
    end

    commit_content = File.read(commit_path)
    files = parse_commit_files(commit_content)

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
    entries = index_content.split("\n").reject { |line| line.empty? }

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
    commit_path = "#{COMMITS_DIR}/#{commit_hash}"

    unless File.exist?(commit_path)
      puts "Invalid commit"
      exit 1
    end

    commit_content = File.read(commit_path)

    timestamp = ""
    message = ""
    commit_content.each_line do |line|
      line = line.chomp
      if line.start_with?("timestamp: ")
        timestamp = line.sub("timestamp: ", "")
      elsif line.start_with?("message: ")
        message = line.sub("message: ", "")
      end
    end

    files = parse_commit_files(commit_content)

    puts "commit #{commit_hash}"
    puts "Date: #{timestamp}"
    puts "Message: #{message}"
    puts "Files:"
    files.keys.sort.each do |f|
      puts "  #{f} #{files[f]}"
    end
  end
end
