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
    let path = Path::new(filename);
    if !path.exists() {
        eprintln!("File not found");
        process::exit(1);
    }

    let mut file = fs::File::open(path).unwrap();
    let mut content = Vec::new();
    file.read_to_end(&mut content).unwrap();

    let hash = minihash(&content);

    fs::write(format!(".minigit/objects/{}", hash), &content).unwrap();

    let index_content = fs::read_to_string(".minigit/index").unwrap();
    let lines: Vec<&str> = index_content.lines().collect();
    if !lines.contains(&filename) {
        let mut new_index = index_content.clone();
        if !new_index.is_empty() && !new_index.ends_with('\n') {
            new_index.push('\n');
        }
        new_index.push_str(filename);
        new_index.push('\n');
        fs::write(".minigit/index", new_index).unwrap();
    }
}

fn cmd_commit(message: &str) {
    let index_content = fs::read_to_string(".minigit/index").unwrap();
    let staged: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();

    if staged.is_empty() {
        eprintln!("Nothing to commit");
        process::exit(1);
    }

    let head = fs::read_to_string(".minigit/HEAD").unwrap();
    let parent = head.trim();
    let parent_str = if parent.is_empty() { "NONE" } else { parent };

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    // Build file entries: filename + blob hash, sorted
    let mut file_entries: Vec<(String, String)> = Vec::new();
    for filename in &staged {
        let content = fs::read(filename).unwrap();
        let hash = minihash(&content);
        file_entries.push((filename.to_string(), hash));
    }
    file_entries.sort_by(|a, b| a.0.cmp(&b.0));

    let mut commit_content = String::new();
    commit_content.push_str(&format!("parent: {}\n", parent_str));
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
    let head = fs::read_to_string(".minigit/HEAD").unwrap();
    let mut current = head.trim().to_string();

    if current.is_empty() {
        println!("No commits");
        return;
    }

    let mut first = true;
    while !current.is_empty() && current != "NONE" {
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
        println!("commit {}", current);
        println!("Date: {}", timestamp);
        println!("Message: {}", message);

        first = false;
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
