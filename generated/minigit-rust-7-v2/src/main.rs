use std::env;
use std::fs;
use std::io::Read;
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
    let mut data = Vec::new();
    fs::File::open(file).unwrap().read_to_end(&mut data).unwrap();
    let hash = minihash(&data);
    fs::write(format!(".minigit/objects/{}", hash), &data).unwrap();

    let index = fs::read_to_string(".minigit/index").unwrap();
    let entries: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if !entries.contains(&file) {
        let mut new_index = index.trim_end().to_string();
        if !new_index.is_empty() {
            new_index.push('\n');
        }
        new_index.push_str(file);
        new_index.push('\n');
        fs::write(".minigit/index", new_index).unwrap();
    }
}

fn cmd_commit(message: &str) {
    let index = fs::read_to_string(".minigit/index").unwrap();
    let mut files: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if files.is_empty() {
        eprintln!("Nothing to commit");
        process::exit(1);
    }
    files.sort();

    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    let parent = if head.is_empty() { "NONE".to_string() } else { head };

    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();

    let mut file_lines = String::new();
    for f in &files {
        let data = fs::read(f).unwrap();
        let hash = minihash(&data);
        file_lines.push_str(&format!("{} {}\n", f, hash));
    }

    let content = format!(
        "parent: {}\ntimestamp: {}\nmessage: {}\nfiles:\n{}",
        parent, timestamp, message, file_lines
    );

    let commit_hash = minihash(content.as_bytes());
    fs::write(format!(".minigit/commits/{}", commit_hash), &content).unwrap();
    fs::write(".minigit/HEAD", &commit_hash).unwrap();
    fs::write(".minigit/index", "").unwrap();
    println!("Committed {}", commit_hash);
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

fn cmd_log() {
    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    if head.is_empty() {
        println!("No commits");
        return;
    }

    let mut current = head;
    loop {
        let path = format!(".minigit/commits/{}", current);
        let content = fs::read_to_string(&path).unwrap();

        let mut timestamp = "";
        let mut message = "";
        let mut parent = "NONE";

        for line in content.lines() {
            if let Some(v) = line.strip_prefix("parent: ") {
                parent = v.trim();
            } else if let Some(v) = line.strip_prefix("timestamp: ") {
                timestamp = v.trim();
            } else if let Some(v) = line.strip_prefix("message: ") {
                message = v.trim();
            }
        }

        println!("commit {}", current);
        println!("Date: {}", timestamp);
        println!("Message: {}", message);
        println!();

        if parent == "NONE" {
            break;
        }
        current = parent.to_string();
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
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                let parts: Vec<&str> = trimmed.splitn(2, ' ').collect();
                if parts.len() == 2 {
                    files.push((parts[0].to_string(), parts[1].to_string()));
                }
            }
        }
    }
    files
}

fn cmd_diff(commit1: &str, commit2: &str) {
    let path1 = format!(".minigit/commits/{}", commit1);
    let path2 = format!(".minigit/commits/{}", commit2);

    if !Path::new(&path1).exists() || !Path::new(&path2).exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content1 = fs::read_to_string(&path1).unwrap();
    let content2 = fs::read_to_string(&path2).unwrap();

    let files1 = parse_commit_files(&content1);
    let files2 = parse_commit_files(&content2);

    let mut all_files: Vec<String> = Vec::new();
    for (f, _) in &files1 {
        if !all_files.contains(f) {
            all_files.push(f.clone());
        }
    }
    for (f, _) in &files2 {
        if !all_files.contains(f) {
            all_files.push(f.clone());
        }
    }
    all_files.sort();

    for f in &all_files {
        let h1 = files1.iter().find(|(name, _)| name == f).map(|(_, h)| h.as_str());
        let h2 = files2.iter().find(|(name, _)| name == f).map(|(_, h)| h.as_str());

        match (h1, h2) {
            (None, Some(_)) => println!("Added: {}", f),
            (Some(_), None) => println!("Removed: {}", f),
            (Some(a), Some(b)) if a != b => println!("Modified: {}", f),
            _ => {}
        }
    }
}

fn cmd_checkout(commit_hash: &str) {
    let commit_path = format!(".minigit/commits/{}", commit_hash);
    if !Path::new(&commit_path).exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&commit_path).unwrap();
    let files = parse_commit_files(&content);

    for (filename, blob_hash) in &files {
        let blob_path = format!(".minigit/objects/{}", blob_hash);
        let blob_content = fs::read(&blob_path).unwrap();
        fs::write(filename, blob_content).unwrap();
    }

    fs::write(".minigit/HEAD", commit_hash).unwrap();
    fs::write(".minigit/index", "").unwrap();
    println!("Checked out {}", commit_hash);
}

fn cmd_reset(commit_hash: &str) {
    let commit_path = format!(".minigit/commits/{}", commit_hash);
    if !Path::new(&commit_path).exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    fs::write(".minigit/HEAD", commit_hash).unwrap();
    fs::write(".minigit/index", "").unwrap();
    println!("Reset to {}", commit_hash);
}

fn cmd_rm(file: &str) {
    let index = fs::read_to_string(".minigit/index").unwrap();
    let entries: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if !entries.contains(&file) {
        eprintln!("File not in index");
        process::exit(1);
    }
    let new_entries: Vec<&str> = entries.into_iter().filter(|&e| e != file).collect();
    let mut new_index = String::new();
    for e in &new_entries {
        new_index.push_str(e);
        new_index.push('\n');
    }
    fs::write(".minigit/index", new_index).unwrap();
}

fn cmd_show(commit_hash: &str) {
    let commit_path = format!(".minigit/commits/{}", commit_hash);
    if !Path::new(&commit_path).exists() {
        eprintln!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&commit_path).unwrap();

    let mut timestamp = "";
    let mut message = "";

    for line in content.lines() {
        if let Some(v) = line.strip_prefix("timestamp: ") {
            timestamp = v.trim();
        } else if let Some(v) = line.strip_prefix("message: ") {
            message = v.trim();
        }
    }

    let mut files = parse_commit_files(&content);
    files.sort_by(|a, b| a.0.cmp(&b.0));

    println!("commit {}", commit_hash);
    println!("Date: {}", timestamp);
    println!("Message: {}", message);
    println!("Files:");
    for (filename, blob_hash) in &files {
        println!("  {} {}", filename, blob_hash);
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
