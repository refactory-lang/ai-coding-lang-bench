# frozen_string_literal: true

module MiniGit
  MINIGIT_DIR = ".minigit"
  OBJECTS_DIR = "#{MINIGIT_DIR}/objects"
  COMMITS_DIR = "#{MINIGIT_DIR}/commits"
  INDEX_FILE  = "#{MINIGIT_DIR}/index"
  HEAD_FILE   = "#{MINIGIT_DIR}/HEAD"

  # MiniHash: FNV-1a variant, 64-bit, 16-char hex output
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
    File.binwrite("#{OBJECTS_DIR}/#{hash}", content)

    # Read current index
    index_content = File.read(INDEX_FILE)
    entries = index_content.split("\n").reject { |line| line.empty? }

    unless entries.include?(filename)
      entries << filename
      File.write(INDEX_FILE, entries.join("\n") + "\n")
    end
  end

  # @rbs message: String
  # @rbs return: void
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

    # Build file lines with hashes
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

  # @rbs return: void
  def self.cmd_log
    head = File.read(HEAD_FILE).strip

    if head.empty?
      puts "No commits"
      return
    end

    current = head
    while current != "" && current != "NONE"
      commit_file = "#{COMMITS_DIR}/#{current}"
      break unless File.exist?(commit_file)

      content = File.read(commit_file)
      lines = content.split("\n")

      timestamp = ""
      message = ""
      parent = ""

      lines.each do |line|
        if line.start_with?("parent: ")
          parent = line.sub("parent: ", "")
        elsif line.start_with?("timestamp: ")
          timestamp = line.sub("timestamp: ", "")
        elsif line.start_with?("message: ")
          message = line.sub("message: ", "")
        end
      end

      puts "commit #{current}"
      puts "Date: #{timestamp}"
      puts "Message: #{message}"
      puts ""

      current = parent
    end
  end

  # @rbs args: Array[String]
  # @rbs return: void
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
      cmd_add(args[1]) #: String
    when "commit"
      if args.length < 3 || args[1] != "-m"
        $stderr.puts "Usage: minigit commit -m \"<message>\""
        exit 1
      end
      cmd_commit(args[2]) #: String
    when "log"
      cmd_log
    else
      $stderr.puts "Unknown command: #{command}"
      exit 1
    end
  end
end
