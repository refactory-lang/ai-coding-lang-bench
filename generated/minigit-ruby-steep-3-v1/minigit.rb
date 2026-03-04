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

  def self.cmd_log
    head = File.read(HEAD_FILE).strip
    if head.empty?
      puts "No commits"
      return
    end

    current = head
    while current && current != "NONE" && !current.empty?
      commit_path = "#{COMMITS_DIR}/#{current}"
      break unless File.exist?(commit_path)

      content = File.read(commit_path)
      lines = content.split("\n")

      parent_hash = ""
      timestamp = ""
      message = ""

      lines.each do |line|
        if line.start_with?("parent: ")
          parent_hash = line.sub("parent: ", "")
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

      current = parent_hash
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
    when "log"
      cmd_log
    else
      $stderr.puts "Unknown command: #{command}"
      exit 1
    end
  end
end
