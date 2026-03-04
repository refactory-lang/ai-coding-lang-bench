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
  case "log":
    log();
    break;
  default:
    console.log("Unknown command");
    process.exit(1);
}
