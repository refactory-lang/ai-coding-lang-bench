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
    let mgdir = Path::new(".minigit");
    if mgdir.exists() {
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

    let obj_path = format!(".minigit/objects/{}", hash);
    fs::write(&obj_path, &contents).unwrap();

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
    let mut filenames: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();
    if filenames.is_empty() {
        println!("Nothing to commit");
        process::exit(1);
    }
    filenames.sort();

    let head = fs::read_to_string(".minigit/HEAD").unwrap().trim().to_string();
    let parent = if head.is_empty() { "NONE".to_string() } else { head };

    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let mut file_lines = String::new();
    for fname in &filenames {
        let content = fs::read(fname).unwrap();
        let hash = minihash(&content);
        file_lines.push_str(&format!("{} {}\n", fname, hash));
    }

    let commit_content = format!(
        "parent: {}\ntimestamp: {}\nmessage: {}\nfiles:\n{}",
        parent, timestamp, message, file_lines
    );

    let commit_hash = minihash(commit_content.as_bytes());
    let commit_path = format!(".minigit/commits/{}", commit_hash);
    fs::write(&commit_path, &commit_content).unwrap();
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
