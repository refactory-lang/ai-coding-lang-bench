import * as fs from "fs";
import * as path from "path";

const MINIGIT_DIR = ".minigit";
const OBJECTS_DIR = path.join(MINIGIT_DIR, "objects");
const COMMITS_DIR = path.join(MINIGIT_DIR, "commits");
const INDEX_FILE = path.join(MINIGIT_DIR, "index");
const HEAD_FILE = path.join(MINIGIT_DIR, "HEAD");

function miniHash(data: Buffer): string {
  let h = BigInt("1469598103934665603");
  const mod = BigInt(1) << BigInt(64);
  const mul = BigInt("1099511628211");
  for (let i = 0; i < data.length; i++) {
    h = h ^ BigInt(data[i]);
    h = (h * mul) % mod;
  }
  return h.toString(16).padStart(16, "0");
}

function cmdInit(): void {
  if (fs.existsSync(MINIGIT_DIR)) {
    console.log("Repository already initialized");
    return;
  }
  fs.mkdirSync(OBJECTS_DIR, { recursive: true });
  fs.mkdirSync(COMMITS_DIR, { recursive: true });
  fs.writeFileSync(INDEX_FILE, "");
  fs.writeFileSync(HEAD_FILE, "");
}

function readIndex(): string[] {
  if (!fs.existsSync(INDEX_FILE)) return [];
  const content = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  if (content === "") return [];
  return content.split("\n");
}

function writeIndex(entries: string[]): void {
  fs.writeFileSync(INDEX_FILE, entries.length > 0 ? entries.join("\n") + "\n" : "");
}

function cmdAdd(filename: string): void {
  if (!fs.existsSync(filename)) {
    console.log("File not found");
    process.exit(1);
  }
  const data = fs.readFileSync(filename);
  const hash = miniHash(data);
  fs.writeFileSync(path.join(OBJECTS_DIR, hash), data);

  const entries = readIndex();
  if (!entries.includes(filename)) {
    entries.push(filename);
    writeIndex(entries);
  }
}

function cmdCommit(message: string): void {
  const entries = readIndex();
  if (entries.length === 0) {
    console.log("Nothing to commit");
    process.exit(1);
  }

  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head === "" ? "NONE" : head;
  const timestamp = Math.floor(Date.now() / 1000);

  const sortedFiles = [...entries].sort();
  const fileLines: string[] = [];
  for (const f of sortedFiles) {
    const data = fs.readFileSync(f);
    const hash = miniHash(data);
    fileLines.push(`${f} ${hash}`);
  }

  const commitContent =
    `parent: ${parent}\n` +
    `timestamp: ${timestamp}\n` +
    `message: ${message}\n` +
    `files:\n` +
    fileLines.join("\n") +
    "\n";

  const commitHash = miniHash(Buffer.from(commitContent, "utf-8"));
  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  writeIndex([]);

  console.log(`Committed ${commitHash}`);
}

function cmdLog(): void {
  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  if (head === "") {
    console.log("No commits");
    return;
  }

  let current: string | null = head;
  while (current) {
    const commitPath = path.join(COMMITS_DIR, current);
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

    console.log(`commit ${current}`);
    console.log(`Date: ${timestamp}`);
    console.log(`Message: ${message}`);
    console.log("");

    current = parentVal === "NONE" ? null : parentVal;
  }
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.log("Usage: minigit <command>");
    process.exit(1);
  }

  const command = args[0];

  switch (command) {
    case "init":
      cmdInit();
      break;
    case "add":
      if (args.length < 2) {
        console.log("Usage: minigit add <file>");
        process.exit(1);
      }
      cmdAdd(args[1]);
      break;
    case "commit":
      if (args.length < 3 || args[1] !== "-m") {
        console.log('Usage: minigit commit -m "<message>"');
        process.exit(1);
      }
      cmdCommit(args[2]);
      break;
    case "log":
      cmdLog();
      break;
    default:
      console.log(`Unknown command: ${command}`);
      process.exit(1);
  }
}

main();
