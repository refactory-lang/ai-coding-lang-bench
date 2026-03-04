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

  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const lines = index.split("\n").filter((l) => l.length > 0);
  if (!lines.includes(filename)) {
    lines.push(filename);
    fs.writeFileSync(INDEX_FILE, lines.join("\n") + "\n");
  }
}

function cmdCommit(message: string): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = index.split("\n").filter((l) => l.length > 0);
  if (files.length === 0) {
    console.log("Nothing to commit");
    process.exit(1);
  }

  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head.length > 0 ? head : "NONE";
  const timestamp = Math.floor(Date.now() / 1000);

  files.sort();
  const fileEntries = files
    .map((f) => {
      const content = fs.readFileSync(f);
      const hash = miniHash(content);
      return `${f} ${hash}`;
    })
    .join("\n");

  const commitContent = `parent: ${parent}\ntimestamp: ${timestamp}\nmessage: ${message}\nfiles:\n${fileEntries}\n`;
  const commitHash = miniHash(Buffer.from(commitContent));

  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");

  console.log(`Committed ${commitHash}`);
}

function cmdLog(): void {
  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  if (head.length === 0) {
    console.log("No commits");
    return;
  }

  let current: string | null = head;
  while (current && current !== "NONE") {
    const commitPath = path.join(COMMITS_DIR, current);
    const content = fs.readFileSync(commitPath, "utf-8");
    const lines = content.split("\n");

    let ts = "";
    let msg = "";
    for (const line of lines) {
      if (line.startsWith("timestamp: ")) ts = line.substring(11);
      if (line.startsWith("message: ")) msg = line.substring(9);
    }

    console.log(`commit ${current}`);
    console.log(`Date: ${ts}`);
    console.log(`Message: ${msg}`);
    console.log("");

    let parent: string | null = null;
    for (const line of lines) {
      if (line.startsWith("parent: ")) {
        parent = line.substring(8);
        break;
      }
    }
    current = parent === "NONE" ? null : parent;
  }
}

function cmdStatus(): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = index.split("\n").filter((l) => l.length > 0);
  if (files.length === 0) {
    console.log("Staged files:");
    console.log("(none)");
  } else {
    console.log("Staged files:");
    for (const f of files) {
      console.log(f);
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
    if (line.startsWith("parent: ")) { parent = line.substring(8); }
    else if (line.startsWith("timestamp: ")) { timestamp = line.substring(11); }
    else if (line.startsWith("message: ")) { message = line.substring(9); }
    else if (line === "files:") { inFiles = true; }
    else if (inFiles && line.length > 0) {
      const idx = line.lastIndexOf(" ");
      files.set(line.substring(0, idx), line.substring(idx + 1));
    }
  }
  return { parent, timestamp, message, files };
}

function cmdDiff(hash1: string, hash2: string): void {
  if (!fs.existsSync(path.join(COMMITS_DIR, hash1)) || !fs.existsSync(path.join(COMMITS_DIR, hash2))) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const c1 = parseCommit(hash1);
  const c2 = parseCommit(hash2);
  const allFiles = new Set<string>();
  c1.files.forEach((_, k) => allFiles.add(k));
  c2.files.forEach((_, k) => allFiles.add(k));
  const sorted = Array.from(allFiles).sort();
  for (const f of sorted) {
    const in1 = c1.files.has(f);
    const in2 = c2.files.has(f);
    if (!in1 && in2) { console.log(`Added: ${f}`); }
    else if (in1 && !in2) { console.log(`Removed: ${f}`); }
    else if (in1 && in2 && c1.files.get(f) !== c2.files.get(f)) { console.log(`Modified: ${f}`); }
  }
}

function cmdCheckout(hash: string): void {
  if (!fs.existsSync(path.join(COMMITS_DIR, hash))) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const c = parseCommit(hash);
  c.files.forEach((blobHash, filename) => {
    const content = fs.readFileSync(path.join(OBJECTS_DIR, blobHash));
    fs.writeFileSync(filename, content);
  });
  fs.writeFileSync(HEAD_FILE, hash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Checked out ${hash}`);
}

function cmdReset(hash: string): void {
  if (!fs.existsSync(path.join(COMMITS_DIR, hash))) {
    console.log("Invalid commit");
    process.exit(1);
  }
  fs.writeFileSync(HEAD_FILE, hash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Reset to ${hash}`);
}

function cmdRm(filename: string): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8");
  const lines = index.split("\n").filter((l) => l.length > 0);
  if (!lines.includes(filename)) {
    console.log("File not in index");
    process.exit(1);
  }
  const newLines = lines.filter((l) => l !== filename);
  fs.writeFileSync(INDEX_FILE, newLines.length > 0 ? newLines.join("\n") + "\n" : "");
}

function cmdShow(hash: string): void {
  if (!fs.existsSync(path.join(COMMITS_DIR, hash))) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const c = parseCommit(hash);
  console.log(`commit ${hash}`);
  console.log(`Date: ${c.timestamp}`);
  console.log(`Message: ${c.message}`);
  console.log("Files:");
  const sorted = Array.from(c.files.entries()).sort((a, b) => a[0].localeCompare(b[0]));
  for (const [filename, blobHash] of sorted) {
    console.log(`  ${filename} ${blobHash}`);
  }
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.log("Usage: minigit <command>");
    process.exit(1);
  }

  const cmd = args[0];
  switch (cmd) {
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
      if (args[1] === "-m" && args.length >= 3) {
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
      console.log(`Unknown command: ${cmd}`);
      process.exit(1);
  }
}

main();
