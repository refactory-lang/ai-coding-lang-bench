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
    when "log"
      cmd_log
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
