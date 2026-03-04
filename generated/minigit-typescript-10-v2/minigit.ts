const fs = require("fs");
const path = require("path");

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

  const filenames = index.split("\n").sort();
  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head === "" ? "NONE" : head;
  const timestamp = Math.floor(Date.now() / 1000);

  let commitContent = `parent: ${parent}\n`;
  commitContent += `timestamp: ${timestamp}\n`;
  commitContent += `message: ${message}\n`;
  commitContent += `files:\n`;

  for (const fname of filenames) {
    const content = fs.readFileSync(fname);
    const hash = miniHash(content);
    commitContent += `${fname} ${hash}\n`;
  }

  const commitHash = miniHash(Buffer.from(commitContent, "utf-8"));
  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");

  console.log(`Committed ${commitHash}`);
}

function cmdStatus(): void {
  const index = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  console.log("Staged files:");
  if (index === "") {
    console.log("(none)");
  } else {
    const entries = index.split("\n");
    for (const e of entries) {
      console.log(e);
    }
  }
}

function parseCommit(hash: any): any {
  const commitPath = path.join(COMMITS_DIR, hash);
  const content = fs.readFileSync(commitPath, "utf-8");
  const lines = content.split("\n");
  let parent = "";
  let timestamp = "";
  let message = "";
  const files = [] as any[];
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
    } else if (inFiles && line.trim() !== "") {
      const spaceIdx = line.indexOf(" ");
      files.push({ name: line.substring(0, spaceIdx), blob: line.substring(spaceIdx + 1) });
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
  const map1 = {} as any;
  const map2 = {} as any;
  for (const f of c1.files) map1[f.name] = f.blob;
  for (const f of c2.files) map2[f.name] = f.blob;
  const allFiles = new Set([...Object.keys(map1), ...Object.keys(map2)]);
  const sorted = Array.from(allFiles).sort();
  for (const fname of sorted) {
    if (!(fname in map1) && fname in map2) {
      console.log(`Added: ${fname}`);
    } else if (fname in map1 && !(fname in map2)) {
      console.log(`Removed: ${fname}`);
    } else if (map1[fname] !== map2[fname]) {
      console.log(`Modified: ${fname}`);
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
  for (const f of c.files) {
    const blobPath = path.join(OBJECTS_DIR, f.blob);
    const content = fs.readFileSync(blobPath);
    fs.writeFileSync(f.name, content);
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
  const index = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  const entries = index === "" ? [] : index.split("\n");
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
  const sorted = c.files.sort((a: any, b: any) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  for (const f of sorted) {
    console.log(`  ${f.name} ${f.blob}`);
  }
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

    let timestamp = "";
    let message = "";
    for (const line of lines) {
      if (line.startsWith("timestamp: ")) {
        timestamp = line.substring("timestamp: ".length);
      } else if (line.startsWith("message: ")) {
        message = line.substring("message: ".length);
      }
    }

    console.log(`commit ${current}`);
    console.log(`Date: ${timestamp}`);
    console.log(`Message: ${message}`);
    console.log("");

    for (const line of lines) {
      if (line.startsWith("parent: ")) {
        current = line.substring("parent: ".length);
        break;
      }
    }
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
