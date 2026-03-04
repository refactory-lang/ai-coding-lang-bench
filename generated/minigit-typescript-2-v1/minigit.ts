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
  for (let i = 0; i < data.length; i++) {
    h = h ^ BigInt(data[i]);
    h = (h * 1099511628211n) % mod;
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

  let index = fs.readFileSync(INDEX_FILE, "utf-8");
  const entries = index ? index.split("\n").filter((l) => l.length > 0) : [];
  if (!entries.includes(filename)) {
    entries.push(filename);
    fs.writeFileSync(INDEX_FILE, entries.join("\n") + "\n");
  }
}

function cmdCommit(message: string): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const entries = index.split("\n").filter((l) => l.length > 0);
  if (entries.length === 0) {
    console.log("Nothing to commit");
    process.exit(1);
  }

  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head || "NONE";
  const timestamp = Math.floor(Date.now() / 1000);

  const sortedFiles = entries.slice().sort();
  const fileLines = sortedFiles
    .map((f) => {
      const content = fs.readFileSync(f);
      const hash = miniHash(content);
      return `${f} ${hash}`;
    })
    .join("\n");

  const commitContent = `parent: ${parent}\ntimestamp: ${timestamp}\nmessage: ${message}\nfiles:\n${fileLines}\n`;
  const commitHash = miniHash(Buffer.from(commitContent));

  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");

  console.log(`Committed ${commitHash}`);
}

function cmdLog(): void {
  let current = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  if (!current) {
    console.log("No commits");
    return;
  }

  while (current && current !== "NONE") {
    const commitPath = path.join(COMMITS_DIR, current);
    const content = fs.readFileSync(commitPath, "utf-8");
    const lines = content.split("\n");

    let ts = "";
    let msg = "";
    for (const line of lines) {
      if (line.startsWith("timestamp: ")) {
        ts = line.substring("timestamp: ".length);
      } else if (line.startsWith("message: ")) {
        msg = line.substring("message: ".length);
      }
    }

    console.log(`commit ${current}`);
    console.log(`Date: ${ts}`);
    console.log(`Message: ${msg}`);
    console.log("");

    // Get parent
    const parentLine = lines.find((l) => l.startsWith("parent: "));
    current = parentLine ? parentLine.substring("parent: ".length) : "";
    if (current === "NONE") break;
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
      if (args[1] === "-m" && args[2]) {
        cmdCommit(args[2]);
      } else {
        console.log("Usage: minigit commit -m <message>");
        process.exit(1);
      }
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
