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
    when "log"
      cmd_log
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
