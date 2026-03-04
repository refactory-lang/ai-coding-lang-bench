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
