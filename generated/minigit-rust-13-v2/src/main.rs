use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

fn minihash(data: &[u8]) -> String {
    let mut h: u64 = 1469598103934665603;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    format!("{:016x}", h)
}

fn cmd_init() {
    let p = Path::new(".minigit");
    if p.exists() {
        println!("Repository already initialized");
        return;
    }
    fs::create_dir_all(".minigit/objects").unwrap();
    fs::create_dir_all(".minigit/commits").unwrap();
    fs::write(".minigit/index", "").unwrap();
    fs::write(".minigit/HEAD", "").unwrap();
}

fn cmd_add(file: &str) {
    if !Path::new(file).exists() {
        eprintln!("File not found");
        process::exit(1);
    }
    let data = fs::read(file).unwrap();
    let hash = minihash(&data);
    fs::write(format!(".minigit/objects/{}", hash), &data).unwrap();

    let index = fs::read_to_string(".minigit/index").unwrap();
    let entries: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if !entries.contains(&file) {
        let mut f = fs::OpenOptions::new().append(true).open(".minigit/index").unwrap();
        writeln!(f, "{}", file).unwrap();
    }
}

fn cmd_commit(message: &str) {
    let index = fs::read_to_string(".minigit/index").unwrap();
    let files: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if files.is_empty() {
        eprintln!("Nothing to commit");
        process::exit(1);
    }

    let head = fs::read_to_string(".minigit/HEAD").unwrap();
    let parent = head.trim();
    let parent_str = if parent.is_empty() { "NONE" } else { parent };

    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();

    let mut sorted_files: Vec<&str> = files.clone();
    sorted_files.sort();

    let mut file_lines = String::new();
    for f in &sorted_files {
        let data = fs::read(f).unwrap();
        let hash = minihash(&data);
        file_lines.push_str(&format!("{} {}\n", f, hash));
    }

    let content = format!(
        "parent: {}\ntimestamp: {}\nmessage: {}\nfiles:\n{}",
        parent_str, timestamp, message, file_lines
    );

    let commit_hash = minihash(content.as_bytes());
    fs::write(format!(".minigit/commits/{}", commit_hash), &content).unwrap();
    fs::write(".minigit/HEAD", &commit_hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Committed {}", commit_hash);
}

fn cmd_log() {
    let head = fs::read_to_string(".minigit/HEAD").unwrap();
    let mut current = head.trim().to_string();

    if current.is_empty() {
        println!("No commits");
        return;
    }

    let mut first = true;
    while !current.is_empty() && current != "NONE" {
        let path = format!(".minigit/commits/{}", current);
        let content = fs::read_to_string(&path).unwrap();

        let mut parent = String::new();
        let mut timestamp = String::new();
        let mut message = String::new();

        for line in content.lines() {
            if let Some(v) = line.strip_prefix("parent: ") {
                parent = v.to_string();
            } else if let Some(v) = line.strip_prefix("timestamp: ") {
                timestamp = v.to_string();
            } else if let Some(v) = line.strip_prefix("message: ") {
                message = v.to_string();
            }
        }

        if !first {
            println!();
        }
        first = false;

        println!("commit {}", current);
        println!("Date: {}", timestamp);
        println!("Message: {}", message);

        current = parent;
    }
}

fn cmd_status() {
    let index = fs::read_to_string(".minigit/index").unwrap();
    let files: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
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
    let path1 = format!(".minigit/commits/{}", hash1);
    let path2 = format!(".minigit/commits/{}", hash2);

    if !Path::new(&path1).exists() || !Path::new(&path2).exists() {
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
    let path = format!(".minigit/commits/{}", hash);
    if !Path::new(&path).exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&path).unwrap();
    let files = parse_commit_files(&content);

    for (name, blob_hash) in &files {
        let blob_path = format!(".minigit/objects/{}", blob_hash);
        let data = fs::read(&blob_path).unwrap();
        fs::write(name, &data).unwrap();
    }

    fs::write(".minigit/HEAD", hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Checked out {}", hash);
}

fn cmd_reset(hash: &str) {
    let path = format!(".minigit/commits/{}", hash);
    if !Path::new(&path).exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    fs::write(".minigit/HEAD", hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Reset to {}", hash);
}

fn cmd_rm(file: &str) {
    let index = fs::read_to_string(".minigit/index").unwrap();
    let entries: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if !entries.contains(&file) {
        eprintln!("File not in index");
        process::exit(1);
    }
    let new_index: Vec<&str> = entries.into_iter().filter(|e| *e != file).collect();
    let mut content = String::new();
    for e in &new_index {
        content.push_str(e);
        content.push('\n');
    }
    fs::write(".minigit/index", &content).unwrap();
}

fn cmd_show(hash: &str) {
    let path = format!(".minigit/commits/{}", hash);
    if !Path::new(&path).exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&path).unwrap();

    let mut timestamp = String::new();
    let mut message = String::new();

    for line in content.lines() {
        if let Some(v) = line.strip_prefix("timestamp: ") {
            timestamp = v.to_string();
        } else if let Some(v) = line.strip_prefix("message: ") {
            message = v.to_string();
        }
    }

    let files = parse_commit_files(&content);

    println!("commit {}", hash);
    println!("Date: {}", timestamp);
    println!("Message: {}", message);
    println!("Files:");
    let mut sorted_files = files;
    sorted_files.sort();
    for (name, blob_hash) in &sorted_files {
        println!("  {} {}", name, blob_hash);
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
