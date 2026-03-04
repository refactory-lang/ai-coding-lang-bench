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
    let mgdir = Path::new(".minigit");
    if mgdir.exists() {
        println!("Repository already initialized");
        return;
    }
    fs::create_dir_all(".minigit/objects").unwrap();
    fs::create_dir_all(".minigit/commits").unwrap();
    fs::File::create(".minigit/index").unwrap();
    fs::File::create(".minigit/HEAD").unwrap();
}

fn cmd_add(filename: &str) {
    if !Path::new(filename).exists() {
        eprintln!("File not found");
        process::exit(1);
    }
    let content = fs::read(filename).unwrap();
    let hash = minihash(&content);
    let obj_path = format!(".minigit/objects/{}", hash);
    fs::write(&obj_path, &content).unwrap();

    let index_content = fs::read_to_string(".minigit/index").unwrap();
    let entries: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();
    if !entries.contains(&filename) {
        let mut f = fs::OpenOptions::new()
            .append(true)
            .open(".minigit/index")
            .unwrap();
        writeln!(f, "{}", filename).unwrap();
    }
}

fn cmd_commit(message: &str) {
    let index_content = fs::read_to_string(".minigit/index").unwrap();
    let entries: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();
    if entries.is_empty() {
        eprintln!("Nothing to commit");
        process::exit(1);
    }

    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    let parent = if head.is_empty() {
        "NONE".to_string()
    } else {
        head
    };

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    // Build file list: for each entry, re-hash the current file content
    let mut file_entries: Vec<(String, String)> = Vec::new();
    for entry in &entries {
        let content = fs::read(entry).unwrap();
        let hash = minihash(&content);
        file_entries.push((entry.to_string(), hash));
    }
    file_entries.sort_by(|a, b| a.0.cmp(&b.0));

    let mut commit_content = String::new();
    commit_content.push_str(&format!("parent: {}\n", parent));
    commit_content.push_str(&format!("timestamp: {}\n", timestamp));
    commit_content.push_str(&format!("message: {}\n", message));
    commit_content.push_str("files:\n");
    for (name, hash) in &file_entries {
        commit_content.push_str(&format!("{} {}\n", name, hash));
    }

    let commit_hash = minihash(commit_content.as_bytes());
    fs::write(format!(".minigit/commits/{}", commit_hash), &commit_content).unwrap();
    fs::write(".minigit/HEAD", &commit_hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Committed {}", commit_hash);
}

fn cmd_log() {
    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    if head.is_empty() {
        println!("No commits");
        return;
    }

    let mut current = head;
    loop {
        let commit_path = format!(".minigit/commits/{}", current);
        let content = fs::read_to_string(&commit_path).unwrap();

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

        println!("commit {}", current);
        println!("Date: {}", timestamp);
        println!("Message: {}", message);
        println!();

        if parent == "NONE" {
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
        "log" => cmd_log(),
        _ => {
            eprintln!("Unknown command: {}", args[1]);
            process::exit(1);
        }
    }
}
