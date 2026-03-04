import * as fs from "fs";
import * as path from "path";

const MINIGIT_DIR = ".minigit";
const OBJECTS_DIR = path.join(MINIGIT_DIR, "objects");
const COMMITS_DIR = path.join(MINIGIT_DIR, "commits");
const INDEX_FILE = path.join(MINIGIT_DIR, "index");
const HEAD_FILE = path.join(MINIGIT_DIR, "HEAD");

function miniHash(data: Buffer): string {
  let h = 1469598103934665603n;
  const mod = 1n << 64n;
  for (const b of data) {
    h = h ^ BigInt(b);
    h = (h * 1099511628211n) % mod;
  }
  return h.toString(16).padStart(16, "0");
}

function init(): void {
  if (fs.existsSync(MINIGIT_DIR)) {
    console.log("Repository already initialized");
    return;
  }
  fs.mkdirSync(OBJECTS_DIR, { recursive: true });
  fs.mkdirSync(COMMITS_DIR, { recursive: true });
  fs.writeFileSync(INDEX_FILE, "");
  fs.writeFileSync(HEAD_FILE, "");
}

function add(filename: string): void {
  if (!fs.existsSync(filename)) {
    console.log("File not found");
    process.exit(1);
  }
  const content = fs.readFileSync(filename);
  const hash = miniHash(content);
  fs.writeFileSync(path.join(OBJECTS_DIR, hash), content);

  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = indexContent.split("\n").filter((f) => f.length > 0);
  if (!files.includes(filename)) {
    files.push(filename);
    fs.writeFileSync(INDEX_FILE, files.join("\n") + "\n");
  }
}

function commit(message: string): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = indexContent.split("\n").filter((f) => f.length > 0);

  if (files.length === 0) {
    console.log("Nothing to commit");
    process.exit(1);
  }

  files.sort();

  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head || "NONE";
  const timestamp = Math.floor(Date.now() / 1000);

  let commitContent = `parent: ${parent}\n`;
  commitContent += `timestamp: ${timestamp}\n`;
  commitContent += `message: ${message}\n`;
  commitContent += `files:\n`;

  for (const file of files) {
    const content = fs.readFileSync(file);
    const hash = miniHash(content);
    commitContent += `${file} ${hash}\n`;
  }

  const commitHash = miniHash(Buffer.from(commitContent));

  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");

  console.log(`Committed ${commitHash}`);
}

function status(): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = indexContent.split("\n").filter((f) => f.length > 0);
  console.log("Staged files:");
  if (files.length === 0) {
    console.log("(none)");
  } else {
    for (const file of files) {
      console.log(file);
    }
  }
}

function parseCommit(hash: string): { parent: string; timestamp: string; message: string; files: [string, string][] } {
  const commitPath = path.join(COMMITS_DIR, hash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const content = fs.readFileSync(commitPath, "utf-8");
  const lines = content.split("\n");

  let parent = "";
  let timestamp = "";
  let message = "";
  const files: [string, string][] = [];
  let inFiles = false;

  for (const line of lines) {
    if (line.startsWith("parent: ")) { parent = line.substring(8); inFiles = false; }
    else if (line.startsWith("timestamp: ")) { timestamp = line.substring(11); inFiles = false; }
    else if (line.startsWith("message: ")) { message = line.substring(9); inFiles = false; }
    else if (line === "files:") { inFiles = true; }
    else if (inFiles && line.trim().length > 0) {
      const spaceIdx = line.lastIndexOf(" ");
      files.push([line.substring(0, spaceIdx), line.substring(spaceIdx + 1)]);
    }
  }

  return { parent, timestamp, message, files };
}

function diff(hash1: string, hash2: string): void {
  const c1 = parseCommit(hash1);
  const c2 = parseCommit(hash2);

  const map1 = new Map<string, string>(c1.files);
  const map2 = new Map<string, string>(c2.files);

  const allFiles = new Set<string>([...map1.keys(), ...map2.keys()]);
  const sorted = [...allFiles].sort();

  for (const file of sorted) {
    const h1 = map1.get(file);
    const h2 = map2.get(file);
    if (!h1 && h2) {
      console.log(`Added: ${file}`);
    } else if (h1 && !h2) {
      console.log(`Removed: ${file}`);
    } else if (h1 && h2 && h1 !== h2) {
      console.log(`Modified: ${file}`);
    }
  }
}

function checkout(commitHash: string): void {
  const c = parseCommit(commitHash);

  for (const [filename, blobHash] of c.files) {
    const blobContent = fs.readFileSync(path.join(OBJECTS_DIR, blobHash));
    fs.writeFileSync(filename, blobContent);
  }

  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Checked out ${commitHash}`);
}

function reset(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }

  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Reset to ${commitHash}`);
}

function rm(filename: string): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = indexContent.split("\n").filter((f) => f.length > 0);
  const idx = files.indexOf(filename);
  if (idx === -1) {
    console.log("File not in index");
    process.exit(1);
  }
  files.splice(idx, 1);
  fs.writeFileSync(INDEX_FILE, files.length > 0 ? files.join("\n") + "\n" : "");
}

function show(commitHash: string): void {
  const c = parseCommit(commitHash);
  console.log(`commit ${commitHash}`);
  console.log(`Date: ${c.timestamp}`);
  console.log(`Message: ${c.message}`);
  console.log("Files:");
  const sorted = [...c.files].sort((a, b) => a[0].localeCompare(b[0]));
  for (const [filename, blobHash] of sorted) {
    console.log(`  ${filename} ${blobHash}`);
  }
}

function log(): void {
  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();

  if (!head) {
    console.log("No commits");
    return;
  }

  let current: string | null = head;
  let first = true;

  while (current && current !== "NONE") {
    const commitPath = path.join(COMMITS_DIR, current);
    if (!fs.existsSync(commitPath)) break;

    const content = fs.readFileSync(commitPath, "utf-8");
    const lines = content.split("\n");

    let parentVal = "";
    let timestamp = "";
    let message = "";

    for (const line of lines) {
      if (line.startsWith("parent: ")) parentVal = line.substring(8);
      else if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
      else if (line.startsWith("message: ")) message = line.substring(9);
    }

    if (!first) console.log("");
    first = false;

    console.log(`commit ${current}`);
    console.log(`Date: ${timestamp}`);
    console.log(`Message: ${message}`);

    current = parentVal === "NONE" ? null : parentVal;
  }
}

const args = process.argv.slice(2);
const command = args[0];

switch (command) {
  case "init":
    init();
    break;
  case "add":
    if (!args[1]) {
      console.log("Usage: minigit add <file>");
      process.exit(1);
    }
    add(args[1]);
    break;
  case "commit":
    if (args[1] !== "-m" || !args[2]) {
      console.log('Usage: minigit commit -m "<message>"');
      process.exit(1);
    }
    commit(args[2]);
    break;
  case "status":
    status();
    break;
  case "log":
    log();
    break;
  case "diff":
    if (!args[1] || !args[2]) {
      console.log("Usage: minigit diff <commit1> <commit2>");
      process.exit(1);
    }
    diff(args[1], args[2]);
    break;
  case "checkout":
    if (!args[1]) {
      console.log("Usage: minigit checkout <commit_hash>");
      process.exit(1);
    }
    checkout(args[1]);
    break;
  case "reset":
    if (!args[1]) {
      console.log("Usage: minigit reset <commit_hash>");
      process.exit(1);
    }
    reset(args[1]);
    break;
  case "rm":
    if (!args[1]) {
      console.log("Usage: minigit rm <file>");
      process.exit(1);
    }
    rm(args[1]);
    break;
  case "show":
    if (!args[1]) {
      console.log("Usage: minigit show <commit_hash>");
      process.exit(1);
    }
    show(args[1]);
    break;
  default:
    console.log("Unknown command");
    process.exit(1);
}
