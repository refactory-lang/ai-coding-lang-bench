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

    let obj_path = Path::new(".minigit/objects").join(&hash);
    fs::write(&obj_path, &data).unwrap();

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
    let mut files: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();
    if files.is_empty() {
        eprintln!("Nothing to commit");
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

fn cmd_log() {
    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    if head.is_empty() {
        println!("No commits");
        return;
    }

    let mut current = head;
    let mut first = true;
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

        if !first {
            println!();
        }
        first = false;
        println!("commit {}", current);
        println!("Date: {}", timestamp);
        println!("Message: {}", message);

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
