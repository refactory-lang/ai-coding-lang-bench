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
  for (const b of data) {
    h = h ^ BigInt(b);
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

  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const entries = index.trim() === "" ? [] : index.trim().split("\n");
  if (!entries.includes(filename)) {
    entries.push(filename);
    fs.writeFileSync(INDEX_FILE, entries.join("\n") + "\n");
  }
}

function cmdCommit(message: string): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  if (index === "") {
    console.log("Nothing to commit");
    process.exit(1);
  }

  const files = index.split("\n").sort();
  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head === "" ? "NONE" : head;
  const timestamp = Math.floor(Date.now() / 1000);

  let commitContent = `parent: ${parent}\ntimestamp: ${timestamp}\nmessage: ${message}\nfiles:\n`;
  for (const f of files) {
    const content = fs.readFileSync(f);
    const hash = miniHash(content);
    commitContent += `${f} ${hash}\n`;
  }

  const commitHash = miniHash(Buffer.from(commitContent));
  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Committed ${commitHash}`);
}

function cmdLog(): void {
  let current = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  if (current === "") {
    console.log("No commits");
    return;
  }

  while (current !== "" && current !== "NONE") {
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

    current = parentVal === "NONE" ? "" : parentVal;
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
  case "commit":
    if (args[1] === "-m") {
      cmdCommit(args[2]);
    }
    break;
  case "log":
    cmdLog();
    break;
  default:
    console.log("Unknown command");
    process.exit(1);
}
