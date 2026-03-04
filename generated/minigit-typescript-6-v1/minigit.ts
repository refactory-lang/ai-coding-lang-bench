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

function cmdAdd(filename: string): void {
  if (!fs.existsSync(filename)) {
    console.log("File not found");
    process.exit(1);
  }
  const content = fs.readFileSync(filename);
  const hash = miniHash(content);
  fs.writeFileSync(path.join(OBJECTS_DIR, hash), content);

  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const lines = indexContent.split("\n").filter((l) => l.length > 0);
  if (!lines.includes(filename)) {
    lines.push(filename);
    fs.writeFileSync(INDEX_FILE, lines.join("\n") + "\n");
  }
}

function cmdCommit(message: string): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = indexContent.split("\n").filter((l) => l.length > 0);
  if (files.length === 0) {
    console.log("Nothing to commit");
    process.exit(1);
  }

  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head.length > 0 ? head : "NONE";
  const timestamp = Math.floor(Date.now() / 1000);

  files.sort();
  const fileEntries: string[] = [];
  for (const f of files) {
    const content = fs.readFileSync(f);
    const hash = miniHash(content);
    fileEntries.push(`${f} ${hash}`);
  }

  const commitContent =
    `parent: ${parent}\ntimestamp: ${timestamp}\nmessage: ${message}\nfiles:\n` +
    fileEntries.join("\n") +
    "\n";

  const commitHash = miniHash(Buffer.from(commitContent));
  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Committed ${commitHash}`);
}

function cmdLog(): void {
  let current = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  if (current.length === 0) {
    console.log("No commits");
    return;
  }
  let first = true;
  while (current.length > 0 && current !== "NONE") {
    const commitPath = path.join(COMMITS_DIR, current);
    const content = fs.readFileSync(commitPath, "utf-8");
    const lines = content.split("\n");

    let ts = "";
    let msg = "";
    for (const line of lines) {
      if (line.startsWith("timestamp: ")) ts = line.substring(11);
      if (line.startsWith("message: ")) msg = line.substring(9);
    }

    if (!first) console.log("");
    console.log(`commit ${current}`);
    console.log(`Date: ${ts}`);
    console.log(`Message: ${msg}`);
    first = false;

    // find parent
    let parentHash = "NONE";
    for (const line of lines) {
      if (line.startsWith("parent: ")) {
        parentHash = line.substring(8);
        break;
      }
    }
    current = parentHash === "NONE" ? "" : parentHash;
  }
}

const args = process.argv.slice(2);
const command = args[0];

switch (command) {
  case "init":
    cmdInit();
    break;
  case "add":
    cmdAdd(args[1]);
    break;
  case "commit": {
    const mIdx = args.indexOf("-m");
    if (mIdx >= 0 && mIdx + 1 < args.length) {
      cmdCommit(args[mIdx + 1]);
    }
    break;
  }
  case "log":
    cmdLog();
    break;
  default:
    console.log(`Unknown command: ${command}`);
    process.exit(1);
}
