use std::env;
use std::fs;
use std::io::Read;
use std::path::Path;
use std::process;

fn minihash(data: &[u8]) -> String {
    let mut h: u64 = 1469598103934665603;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    format!("{:016x}", h)
}

fn cmd_init() {
    let base = Path::new(".minigit");
    if base.exists() {
        println!("Repository already initialized");
        return;
    }
    fs::create_dir_all(base.join("objects")).unwrap();
    fs::create_dir_all(base.join("commits")).unwrap();
    fs::write(base.join("index"), "").unwrap();
    fs::write(base.join("HEAD"), "").unwrap();
}

fn cmd_add(filename: &str) {
    let path = Path::new(filename);
    if !path.exists() {
        eprintln!("File not found");
        process::exit(1);
    }

    let mut data = Vec::new();
    fs::File::open(path).unwrap().read_to_end(&mut data).unwrap();
    let hash = minihash(&data);

    let obj_path = Path::new(".minigit").join("objects").join(&hash);
    fs::write(&obj_path, &data).unwrap();

    let index_path = Path::new(".minigit").join("index");
    let index_content = fs::read_to_string(&index_path).unwrap();
    let lines: Vec<&str> = index_content.lines().collect();
    if !lines.contains(&filename) {
        let mut new_content = index_content.clone();
        if !new_content.is_empty() && !new_content.ends_with('\n') {
            new_content.push('\n');
        }
        new_content.push_str(filename);
        new_content.push('\n');
        fs::write(&index_path, new_content).unwrap();
    }
}

fn cmd_commit(message: &str) {
    let index_path = Path::new(".minigit").join("index");
    let index_content = fs::read_to_string(&index_path).unwrap();
    let mut files: Vec<String> = index_content
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect();

    if files.is_empty() {
        eprintln!("Nothing to commit");
        process::exit(1);
    }

    files.sort();

    let head_path = Path::new(".minigit").join("HEAD");
    let parent = fs::read_to_string(&head_path).unwrap().trim().to_string();
    let parent_str = if parent.is_empty() { "NONE" } else { &parent };

    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let mut file_entries = String::new();
    for f in &files {
        let data = fs::read(f).unwrap();
        let hash = minihash(&data);
        file_entries.push_str(&format!("{} {}\n", f, hash));
    }

    let commit_content = format!(
        "parent: {}\ntimestamp: {}\nmessage: {}\nfiles:\n{}",
        parent_str, timestamp, message, file_entries
    );

    let commit_hash = minihash(commit_content.as_bytes());
    let commit_path = Path::new(".minigit").join("commits").join(&commit_hash);
    fs::write(&commit_path, &commit_content).unwrap();
    fs::write(&head_path, &commit_hash).unwrap();
    fs::write(&index_path, "").unwrap();

    println!("Committed {}", commit_hash);
}

fn cmd_status() {
    let index_path = Path::new(".minigit").join("index");
    let index_content = fs::read_to_string(&index_path).unwrap();
    let files: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();

    println!("Staged files:");
    if files.is_empty() {
        println!("(none)");
    } else {
        for f in &files {
            println!("{}", f);
        }
    }
}

fn parse_commit_files(content: &str) -> Vec<(String, String)> {
    let mut in_files = false;
    let mut files = Vec::new();
    for line in content.lines() {
        if line == "files:" {
            in_files = true;
            continue;
        }
        if in_files {
            let parts: Vec<&str> = line.splitn(2, ' ').collect();
            if parts.len() == 2 {
                files.push((parts[0].to_string(), parts[1].to_string()));
            }
        }
    }
    files
}

fn cmd_diff(hash1: &str, hash2: &str) {
    let path1 = Path::new(".minigit").join("commits").join(hash1);
    let path2 = Path::new(".minigit").join("commits").join(hash2);

    if !path1.exists() || !path2.exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content1 = fs::read_to_string(&path1).unwrap();
    let content2 = fs::read_to_string(&path2).unwrap();

    let files1 = parse_commit_files(&content1);
    let files2 = parse_commit_files(&content2);

    let mut all_names: Vec<String> = Vec::new();
    for (name, _) in &files1 {
        if !all_names.contains(name) {
            all_names.push(name.clone());
        }
    }
    for (name, _) in &files2 {
        if !all_names.contains(name) {
            all_names.push(name.clone());
        }
    }
    all_names.sort();

    for name in &all_names {
        let h1 = files1.iter().find(|(n, _)| n == name).map(|(_, h)| h.as_str());
        let h2 = files2.iter().find(|(n, _)| n == name).map(|(_, h)| h.as_str());

        match (h1, h2) {
            (None, Some(_)) => println!("Added: {}", name),
            (Some(_), None) => println!("Removed: {}", name),
            (Some(a), Some(b)) if a != b => println!("Modified: {}", name),
            _ => {}
        }
    }
}

fn cmd_checkout(hash: &str) {
    let commit_path = Path::new(".minigit").join("commits").join(hash);
    if !commit_path.exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&commit_path).unwrap();
    let files = parse_commit_files(&content);

    for (name, blob_hash) in &files {
        let blob_path = Path::new(".minigit").join("objects").join(blob_hash);
        let data = fs::read(&blob_path).unwrap();
        fs::write(name, data).unwrap();
    }

    fs::write(Path::new(".minigit").join("HEAD"), hash).unwrap();
    fs::write(Path::new(".minigit").join("index"), "").unwrap();

    println!("Checked out {}", hash);
}

fn cmd_reset(hash: &str) {
    let commit_path = Path::new(".minigit").join("commits").join(hash);
    if !commit_path.exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    fs::write(Path::new(".minigit").join("HEAD"), hash).unwrap();
    fs::write(Path::new(".minigit").join("index"), "").unwrap();

    println!("Reset to {}", hash);
}

fn cmd_rm(filename: &str) {
    let index_path = Path::new(".minigit").join("index");
    let index_content = fs::read_to_string(&index_path).unwrap();
    let files: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();

    if !files.contains(&filename) {
        eprintln!("File not in index");
        process::exit(1);
    }

    let new_content: String = files
        .iter()
        .filter(|&&f| f != filename)
        .map(|f| format!("{}\n", f))
        .collect();
    fs::write(&index_path, new_content).unwrap();
}

fn cmd_show(hash: &str) {
    let commit_path = Path::new(".minigit").join("commits").join(hash);
    if !commit_path.exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&commit_path).unwrap();

    let mut timestamp = String::new();
    let mut message = String::new();

    for line in content.lines() {
        if let Some(val) = line.strip_prefix("timestamp: ") {
            timestamp = val.to_string();
        } else if let Some(val) = line.strip_prefix("message: ") {
            message = val.to_string();
        }
    }

    let files = parse_commit_files(&content);

    println!("commit {}", hash);
    println!("Date: {}", timestamp);
    println!("Message: {}", message);
    println!("Files:");
    for (name, blob_hash) in &files {
        println!("  {} {}", name, blob_hash);
    }
}

fn cmd_log() {
    let head_path = Path::new(".minigit").join("HEAD");
    let head = fs::read_to_string(&head_path).unwrap().trim().to_string();

    if head.is_empty() {
        println!("No commits");
        return;
    }

    let mut current = head;
    loop {
        let commit_path = Path::new(".minigit").join("commits").join(&current);
        let content = fs::read_to_string(&commit_path).unwrap();

        let mut parent = String::new();
        let mut timestamp = String::new();
        let mut message = String::new();

        for line in content.lines() {
            if let Some(val) = line.strip_prefix("parent: ") {
                parent = val.to_string();
            } else if let Some(val) = line.strip_prefix("timestamp: ") {
                timestamp = val.to_string();
            } else if let Some(val) = line.strip_prefix("message: ") {
                message = val.to_string();
            }
        }

        println!("commit {}", current);
        println!("Date: {}", timestamp);
        println!("Message: {}", message);
        println!();

        if parent == "NONE" || parent.is_empty() {
            break;
        }
        current = parent;
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: minigit <command>");
        process::exit(1);
    }

    match args[1].as_str() {
        "init" => cmd_init(),
        "add" => {
            if args.len() < 3 {
                eprintln!("Usage: minigit add <file>");
                process::exit(1);
            }
            cmd_add(&args[2]);
        }
        "commit" => {
            if args.len() < 4 || args[2] != "-m" {
                eprintln!("Usage: minigit commit -m \"<message>\"");
                process::exit(1);
            }
            cmd_commit(&args[3]);
        }
        "status" => cmd_status(),
        "log" => cmd_log(),
        "diff" => {
            if args.len() < 4 {
                eprintln!("Usage: minigit diff <commit1> <commit2>");
                process::exit(1);
            }
            cmd_diff(&args[2], &args[3]);
        }
        "checkout" => {
            if args.len() < 3 {
                eprintln!("Usage: minigit checkout <commit_hash>");
                process::exit(1);
            }
            cmd_checkout(&args[2]);
        }
        "reset" => {
            if args.len() < 3 {
                eprintln!("Usage: minigit reset <commit_hash>");
                process::exit(1);
            }
            cmd_reset(&args[2]);
        }
        "rm" => {
            if args.len() < 3 {
                eprintln!("Usage: minigit rm <file>");
                process::exit(1);
            }
            cmd_rm(&args[2]);
        }
        "show" => {
            if args.len() < 3 {
                eprintln!("Usage: minigit show <commit_hash>");
                process::exit(1);
            }
            cmd_show(&args[2]);
        }
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            process::exit(1);
        }
    }
}
