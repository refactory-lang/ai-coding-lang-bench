use std::env;
use std::fs;
use std::io::Read;
use std::path::Path;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

const MINIGIT_DIR: &str = ".minigit";

fn minihash(data: &[u8]) -> String {
    let mut h: u64 = 1469598103934665603;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    format!("{:016x}", h)
}

fn cmd_init() {
    let mgdir = Path::new(MINIGIT_DIR);
    if mgdir.exists() {
        println!("Repository already initialized");
        return;
    }
    fs::create_dir_all(mgdir.join("objects")).unwrap();
    fs::create_dir_all(mgdir.join("commits")).unwrap();
    fs::write(mgdir.join("index"), "").unwrap();
    fs::write(mgdir.join("HEAD"), "").unwrap();
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

    let obj_path = Path::new(MINIGIT_DIR).join("objects").join(&hash);
    fs::write(&obj_path, &data).unwrap();

    let index_path = Path::new(MINIGIT_DIR).join("index");
    let index_content = fs::read_to_string(&index_path).unwrap_or_default();
    let mut entries: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();
    if !entries.contains(&filename) {
        entries.push(filename);
        let mut out = entries.join("\n");
        if !out.is_empty() {
            out.push('\n');
        }
        fs::write(&index_path, out).unwrap();
    }
}

fn cmd_commit(message: &str) {
    let index_path = Path::new(MINIGIT_DIR).join("index");
    let index_content = fs::read_to_string(&index_path).unwrap_or_default();
    let entries: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();

    if entries.is_empty() {
        eprintln!("Nothing to commit");
        process::exit(1);
    }

    let head_path = Path::new(MINIGIT_DIR).join("HEAD");
    let parent = fs::read_to_string(&head_path).unwrap_or_default().trim().to_string();
    let parent_str = if parent.is_empty() { "NONE" } else { &parent };

    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();

    // Build file entries sorted
    let mut file_entries: Vec<(String, String)> = Vec::new();
    for &fname in &entries {
        let mut data = Vec::new();
        fs::File::open(fname).unwrap().read_to_end(&mut data).unwrap();
        let hash = minihash(&data);
        file_entries.push((fname.to_string(), hash));
    }
    file_entries.sort_by(|a, b| a.0.cmp(&b.0));

    let mut commit_content = format!(
        "parent: {}\ntimestamp: {}\nmessage: {}\nfiles:\n",
        parent_str, timestamp, message
    );
    for (fname, hash) in &file_entries {
        commit_content.push_str(&format!("{} {}\n", fname, hash));
    }

    let commit_hash = minihash(commit_content.as_bytes());
    fs::write(Path::new(MINIGIT_DIR).join("commits").join(&commit_hash), &commit_content).unwrap();
    fs::write(&head_path, &commit_hash).unwrap();
    fs::write(&index_path, "").unwrap();

    println!("Committed {}", commit_hash);
}

fn cmd_log() {
    let head_path = Path::new(MINIGIT_DIR).join("HEAD");
    let head = fs::read_to_string(&head_path).unwrap_or_default().trim().to_string();

    if head.is_empty() {
        println!("No commits");
        return;
    }

    let mut current = head;
    let mut first = true;
    while !current.is_empty() && current != "NONE" {
        let commit_path = Path::new(MINIGIT_DIR).join("commits").join(&current);
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
        println!("commit {}", current);
        println!("Date: {}", timestamp);
        println!("Message: {}", message);
        first = false;

        current = if parent == "NONE" { String::new() } else { parent };
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
