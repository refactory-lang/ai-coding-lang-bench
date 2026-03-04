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
    when "log"
      cmd_log
    else
      $stderr.puts "Unknown command: #{command}"
      exit 1
    end
  end
end
