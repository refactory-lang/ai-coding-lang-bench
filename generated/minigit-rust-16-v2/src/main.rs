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
    let path = Path::new(".minigit");
    if path.exists() {
        println!("Repository already initialized");
        return;
    }
    fs::create_dir_all(".minigit/objects").unwrap();
    fs::create_dir_all(".minigit/commits").unwrap();
    fs::write(".minigit/index", "").unwrap();
    fs::write(".minigit/HEAD", "").unwrap();
}

fn cmd_add(filename: &str) {
    if !Path::new(filename).exists() {
        println!("File not found");
        process::exit(1);
    }
    let mut file = fs::File::open(filename).unwrap();
    let mut contents = Vec::new();
    file.read_to_end(&mut contents).unwrap();
    let hash = minihash(&contents);

    fs::write(format!(".minigit/objects/{}", hash), &contents).unwrap();

    let index = fs::read_to_string(".minigit/index").unwrap();
    let lines: Vec<&str> = index.lines().collect();
    if !lines.contains(&filename) {
        let mut new_index = index.clone();
        if !new_index.is_empty() && !new_index.ends_with('\n') {
            new_index.push('\n');
        }
        new_index.push_str(filename);
        new_index.push('\n');
        fs::write(".minigit/index", new_index).unwrap();
    }
}

fn cmd_commit(message: &str) {
    let index = fs::read_to_string(".minigit/index").unwrap();
    let mut files: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if files.is_empty() {
        println!("Nothing to commit");
        process::exit(1);
    }
    files.sort();
    files.dedup();

    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    let parent = if head.is_empty() { "NONE".to_string() } else { head };

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let mut commit_content = String::new();
    commit_content.push_str(&format!("parent: {}\n", parent));
    commit_content.push_str(&format!("timestamp: {}\n", timestamp));
    commit_content.push_str(&format!("message: {}\n", message));
    commit_content.push_str("files:\n");

    for f in &files {
        let data = fs::read(f).unwrap();
        let hash = minihash(&data);
        commit_content.push_str(&format!("{} {}\n", f, hash));
    }

    let commit_hash = minihash(commit_content.as_bytes());
    fs::write(format!(".minigit/commits/{}", commit_hash), &commit_content).unwrap();
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

fn parse_commit(content: &str) -> (String, String, String, Vec<(String, String)>) {
    let mut parent = String::new();
    let mut timestamp = String::new();
    let mut message = String::new();
    let mut files = Vec::new();
    let mut in_files = false;

    for line in content.lines() {
        if in_files {
            let parts: Vec<&str> = line.splitn(2, ' ').collect();
            if parts.len() == 2 {
                files.push((parts[0].to_string(), parts[1].to_string()));
            }
        } else if let Some(val) = line.strip_prefix("parent: ") {
            parent = val.to_string();
        } else if let Some(val) = line.strip_prefix("timestamp: ") {
            timestamp = val.to_string();
        } else if let Some(val) = line.strip_prefix("message: ") {
            message = val.to_string();
        } else if line == "files:" {
            in_files = true;
        }
    }
    (parent, timestamp, message, files)
}

fn cmd_diff(hash1: &str, hash2: &str) {
    let path1 = format!(".minigit/commits/{}", hash1);
    let path2 = format!(".minigit/commits/{}", hash2);

    if !Path::new(&path1).exists() || !Path::new(&path2).exists() {
        println!("Invalid commit");
        process::exit(1);
    }

    let content1 = fs::read_to_string(&path1).unwrap();
    let content2 = fs::read_to_string(&path2).unwrap();

    let (_, _, _, files1) = parse_commit(&content1);
    let (_, _, _, files2) = parse_commit(&content2);

    let mut all_files = std::collections::BTreeSet::new();
    for (f, _) in &files1 { all_files.insert(f.clone()); }
    for (f, _) in &files2 { all_files.insert(f.clone()); }

    for f in &all_files {
        let h1 = files1.iter().find(|(n, _)| n == f).map(|(_, h)| h.as_str());
        let h2 = files2.iter().find(|(n, _)| n == f).map(|(_, h)| h.as_str());
        match (h1, h2) {
            (None, Some(_)) => println!("Added: {}", f),
            (Some(_), None) => println!("Removed: {}", f),
            (Some(a), Some(b)) if a != b => println!("Modified: {}", f),
            _ => {}
        }
    }
}

fn cmd_checkout(hash: &str) {
    let commit_path = format!(".minigit/commits/{}", hash);
    if !Path::new(&commit_path).exists() {
        println!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&commit_path).unwrap();
    let (_, _, _, files) = parse_commit(&content);

    for (filename, blob_hash) in &files {
        let blob_path = format!(".minigit/objects/{}", blob_hash);
        let blob_content = fs::read(&blob_path).unwrap();
        fs::write(filename, &blob_content).unwrap();
    }

    fs::write(".minigit/HEAD", hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Checked out {}", hash);
}

fn cmd_reset(hash: &str) {
    let commit_path = format!(".minigit/commits/{}", hash);
    if !Path::new(&commit_path).exists() {
        println!("Invalid commit");
        process::exit(1);
    }

    fs::write(".minigit/HEAD", hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Reset to {}", hash);
}

fn cmd_rm(filename: &str) {
    let index = fs::read_to_string(".minigit/index").unwrap();
    let files: Vec<&str> = index.lines().filter(|l| !l.is_empty()).collect();
    if !files.contains(&filename) {
        println!("File not in index");
        process::exit(1);
    }
    let new_index: String = files.iter()
        .filter(|&&f| f != filename)
        .map(|f| format!("{}\n", f))
        .collect();
    fs::write(".minigit/index", new_index).unwrap();
}

fn cmd_show(hash: &str) {
    let commit_path = format!(".minigit/commits/{}", hash);
    if !Path::new(&commit_path).exists() {
        println!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&commit_path).unwrap();
    let (_, timestamp, message, files) = parse_commit(&content);

    println!("commit {}", hash);
    println!("Date: {}", timestamp);
    println!("Message: {}", message);
    println!("Files:");
    for (filename, blob_hash) in &files {
        println!("  {} {}", filename, blob_hash);
    }
}

fn cmd_log() {
    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    if head.is_empty() {
        println!("No commits");
        return;
    }

    let mut current = head;
    let mut first = true;
    while current != "NONE" && !current.is_empty() {
        let commit_path = format!(".minigit/commits/{}", current);
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
