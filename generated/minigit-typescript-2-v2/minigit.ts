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

function cmdStatus(): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const entries = index.split("\n").filter((l) => l.length > 0);
  console.log("Staged files:");
  if (entries.length === 0) {
    console.log("(none)");
  } else {
    for (const e of entries) {
      console.log(e);
    }
  }
}

function parseCommit(hash: string): { parent: string; timestamp: string; message: string; files: Map<string, string> } {
  const commitPath = path.join(COMMITS_DIR, hash);
  const content = fs.readFileSync(commitPath, "utf-8");
  const lines = content.split("\n");
  let parent = "";
  let timestamp = "";
  let message = "";
  const files = new Map<string, string>();
  let inFiles = false;
  for (const line of lines) {
    if (inFiles) {
      if (line.trim().length > 0) {
        const parts = line.split(" ");
        files.set(parts[0], parts[1]);
      }
    } else if (line.startsWith("parent: ")) {
      parent = line.substring("parent: ".length);
    } else if (line.startsWith("timestamp: ")) {
      timestamp = line.substring("timestamp: ".length);
    } else if (line.startsWith("message: ")) {
      message = line.substring("message: ".length);
    } else if (line === "files:") {
      inFiles = true;
    }
  }
  return { parent, timestamp, message, files };
}

function cmdDiff(hash1: string, hash2: string): void {
  const commitPath1 = path.join(COMMITS_DIR, hash1);
  const commitPath2 = path.join(COMMITS_DIR, hash2);
  if (!fs.existsSync(commitPath1) || !fs.existsSync(commitPath2)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const c1 = parseCommit(hash1);
  const c2 = parseCommit(hash2);
  const allFiles = new Set<string>();
  for (const f of c1.files.keys()) allFiles.add(f);
  for (const f of c2.files.keys()) allFiles.add(f);
  const sorted = Array.from(allFiles).sort();
  for (const f of sorted) {
    const h1 = c1.files.get(f);
    const h2 = c2.files.get(f);
    if (!h1 && h2) {
      console.log(`Added: ${f}`);
    } else if (h1 && !h2) {
      console.log(`Removed: ${f}`);
    } else if (h1 && h2 && h1 !== h2) {
      console.log(`Modified: ${f}`);
    }
  }
}

function cmdCheckout(hash: string): void {
  const commitPath = path.join(COMMITS_DIR, hash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const c = parseCommit(hash);
  for (const [filename, blobHash] of c.files) {
    const blobPath = path.join(OBJECTS_DIR, blobHash);
    const content = fs.readFileSync(blobPath);
    fs.writeFileSync(filename, content);
  }
  fs.writeFileSync(HEAD_FILE, hash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Checked out ${hash}`);
}

function cmdReset(hash: string): void {
  const commitPath = path.join(COMMITS_DIR, hash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  fs.writeFileSync(HEAD_FILE, hash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Reset to ${hash}`);
}

function cmdRm(filename: string): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const entries = index.split("\n").filter((l) => l.length > 0);
  const idx = entries.indexOf(filename);
  if (idx === -1) {
    console.log("File not in index");
    process.exit(1);
  }
  entries.splice(idx, 1);
  fs.writeFileSync(INDEX_FILE, entries.length > 0 ? entries.join("\n") + "\n" : "");
}

function cmdShow(hash: string): void {
  const commitPath = path.join(COMMITS_DIR, hash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const c = parseCommit(hash);
  console.log(`commit ${hash}`);
  console.log(`Date: ${c.timestamp}`);
  console.log(`Message: ${c.message}`);
  console.log("Files:");
  const sorted = Array.from(c.files.keys()).sort();
  for (const f of sorted) {
    console.log(`  ${f} ${c.files.get(f)}`);
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
    case "status":
      cmdStatus();
      break;
    case "log":
      cmdLog();
      break;
    case "diff":
      if (args.length < 3) {
        console.log("Usage: minigit diff <commit1> <commit2>");
        process.exit(1);
      }
      cmdDiff(args[1], args[2]);
      break;
    case "checkout":
      if (args.length < 2) {
        console.log("Usage: minigit checkout <commit_hash>");
        process.exit(1);
      }
      cmdCheckout(args[1]);
      break;
    case "reset":
      if (args.length < 2) {
        console.log("Usage: minigit reset <commit_hash>");
        process.exit(1);
      }
      cmdReset(args[1]);
      break;
    case "rm":
      if (args.length < 2) {
        console.log("Usage: minigit rm <file>");
        process.exit(1);
      }
      cmdRm(args[1]);
      break;
    case "show":
      if (args.length < 2) {
        console.log("Usage: minigit show <commit_hash>");
        process.exit(1);
      }
      cmdShow(args[1]);
      break;
    default:
      console.log(`Unknown command: ${command}`);
      process.exit(1);
  }
}

main();
