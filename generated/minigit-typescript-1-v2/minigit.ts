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

  const sortedFiles = [...files].sort();
  const fileEntries = sortedFiles
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

function cmdStatus(): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const files = indexContent.split("\n").filter((l) => l.length > 0);
  console.log("Staged files:");
  if (files.length === 0) {
    console.log("(none)");
  } else {
    for (const f of files) {
      console.log(f);
    }
  }
}

function parseCommit(hash: string): { parent: string; timestamp: string; message: string; files: [string, string][] } {
  const content = fs.readFileSync(path.join(COMMITS_DIR, hash), "utf-8");
  const lines = content.split("\n");
  let parent = "NONE";
  let timestamp = "";
  let message = "";
  const files: [string, string][] = [];
  let inFiles = false;
  for (const line of lines) {
    if (line.startsWith("parent: ")) {
      parent = line.substring("parent: ".length);
    } else if (line.startsWith("timestamp: ")) {
      timestamp = line.substring("timestamp: ".length);
    } else if (line.startsWith("message: ")) {
      message = line.substring("message: ".length);
    } else if (line === "files:") {
      inFiles = true;
    } else if (inFiles && line.length > 0) {
      const spaceIdx = line.indexOf(" ");
      files.push([line.substring(0, spaceIdx), line.substring(spaceIdx + 1)]);
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
  const map1 = new Map<string, string>(c1.files);
  const map2 = new Map<string, string>(c2.files);
  const allFiles = new Set<string>([...map1.keys(), ...map2.keys()]);
  const sorted = [...allFiles].sort();
  for (const f of sorted) {
    const h1 = map1.get(f);
    const h2 = map2.get(f);
    if (!h1 && h2) {
      console.log(`Added: ${f}`);
    } else if (h1 && !h2) {
      console.log(`Removed: ${f}`);
    } else if (h1 && h2 && h1 !== h2) {
      console.log(`Modified: ${f}`);
    }
  }
}

function cmdCheckout(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const c = parseCommit(commitHash);
  for (const [filename, blobHash] of c.files) {
    const blobContent = fs.readFileSync(path.join(OBJECTS_DIR, blobHash));
    fs.writeFileSync(filename, blobContent);
  }
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Checked out ${commitHash}`);
}

function cmdReset(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Reset to ${commitHash}`);
}

function cmdRm(filename: string): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const lines = indexContent.split("\n").filter((l) => l.length > 0);
  if (!lines.includes(filename)) {
    console.log("File not in index");
    process.exit(1);
  }
  const newLines = lines.filter((l) => l !== filename);
  fs.writeFileSync(INDEX_FILE, newLines.length > 0 ? newLines.join("\n") + "\n" : "");
}

function cmdShow(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
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

    const parentLine = lines.find((l) => l.startsWith("parent: "));
    const parent = parentLine ? parentLine.substring("parent: ".length) : "NONE";
    current = parent === "NONE" ? null : parent;
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
  case "status":
    cmdStatus();
    break;
  case "log":
    cmdLog();
    break;
  case "diff":
    cmdDiff(args[1], args[2]);
    break;
  case "checkout":
    cmdCheckout(args[1]);
    break;
  case "reset":
    cmdReset(args[1]);
    break;
  case "rm":
    cmdRm(args[1]);
    break;
  case "show":
    cmdShow(args[1]);
    break;
  default:
    console.log("Unknown command");
    process.exit(1);
}
