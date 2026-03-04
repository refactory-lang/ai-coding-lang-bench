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

fn cmd_status() {
    let index_content = fs::read_to_string(".minigit/index").unwrap();
    let filenames: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();
    println!("Staged files:");
    if filenames.is_empty() {
        println!("(none)");
    } else {
        for f in &filenames {
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
        println!("Invalid commit");
        process::exit(1);
    }

    let content1 = fs::read_to_string(&path1).unwrap();
    let content2 = fs::read_to_string(&path2).unwrap();

    let files1 = parse_commit_files(&content1);
    let files2 = parse_commit_files(&content2);

    let mut map1 = std::collections::BTreeMap::new();
    for (name, hash) in &files1 {
        map1.insert(name.clone(), hash.clone());
    }
    let mut map2 = std::collections::BTreeMap::new();
    for (name, hash) in &files2 {
        map2.insert(name.clone(), hash.clone());
    }

    let mut all_files = std::collections::BTreeSet::new();
    for k in map1.keys() {
        all_files.insert(k.clone());
    }
    for k in map2.keys() {
        all_files.insert(k.clone());
    }

    for f in &all_files {
        match (map1.get(f), map2.get(f)) {
            (None, Some(_)) => println!("Added: {}", f),
            (Some(_), None) => println!("Removed: {}", f),
            (Some(h1), Some(h2)) => {
                if h1 != h2 {
                    println!("Modified: {}", f);
                }
            }
            _ => {}
        }
    }
}

fn cmd_checkout(commit_hash: &str) {
    let commit_path = format!(".minigit/commits/{}", commit_hash);
    if !Path::new(&commit_path).exists() {
        println!("Invalid commit");
        process::exit(1);
    }

    let content = fs::read_to_string(&commit_path).unwrap();
    let files = parse_commit_files(&content);

    for (filename, blob_hash) in &files {
        let blob_path = format!(".minigit/objects/{}", blob_hash);
        let blob_content = fs::read(&blob_path).unwrap();
        fs::write(filename, &blob_content).unwrap();
    }

    fs::write(".minigit/HEAD", commit_hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Checked out {}", commit_hash);
}

fn cmd_reset(commit_hash: &str) {
    let commit_path = format!(".minigit/commits/{}", commit_hash);
    if !Path::new(&commit_path).exists() {
        println!("Invalid commit");
        process::exit(1);
    }

    fs::write(".minigit/HEAD", commit_hash).unwrap();
    fs::write(".minigit/index", "").unwrap();

    println!("Reset to {}", commit_hash);
}

fn cmd_rm(filename: &str) {
    let index_content = fs::read_to_string(".minigit/index").unwrap();
    let lines: Vec<&str> = index_content.lines().filter(|l| !l.is_empty()).collect();
    if !lines.contains(&filename) {
        println!("File not in index");
        process::exit(1);
    }
    let new_lines: Vec<&str> = lines.into_iter().filter(|l| *l != filename).collect();
    let mut new_index = String::new();
    for l in &new_lines {
        new_index.push_str(l);
        new_index.push('\n');
    }
    fs::write(".minigit/index", new_index).unwrap();
}

fn cmd_show(commit_hash: &str) {
    let commit_path = format!(".minigit/commits/{}", commit_hash);
    if !Path::new(&commit_path).exists() {
        println!("Invalid commit");
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

    println!("commit {}", commit_hash);
    println!("Date: {}", timestamp);
    println!("Message: {}", message);
    println!("Files:");
    for (name, hash) in &files {
        println!("  {} {}", name, hash);
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
