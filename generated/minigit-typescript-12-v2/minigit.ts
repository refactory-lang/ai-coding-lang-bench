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

  // Read current index
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const entries = indexContent.trim() === "" ? [] : indexContent.trim().split("\n");
  if (!entries.includes(filename)) {
    entries.push(filename);
    fs.writeFileSync(INDEX_FILE, entries.join("\n") + "\n");
  }
}

function cmdCommit(message: string): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  if (indexContent === "") {
    console.log("Nothing to commit");
    process.exit(1);
  }

  const files = indexContent.split("\n").sort();
  const headContent = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = headContent === "" ? "NONE" : headContent;
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

function cmdLog(): void {
  let current = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  if (current === "") {
    console.log("No commits");
    return;
  }

  let first = true;
  while (current !== "" && current !== "NONE") {
    const commitPath = path.join(COMMITS_DIR, current);
    const content = fs.readFileSync(commitPath, "utf-8");

    if (!first) {
      console.log("");
    }
    first = false;

    let timestampVal = "";
    let messageVal = "";
    for (const line of content.split("\n")) {
      if (line.startsWith("timestamp: ")) {
        timestampVal = line.substring("timestamp: ".length);
      } else if (line.startsWith("message: ")) {
        messageVal = line.substring("message: ".length);
      } else if (line.startsWith("parent: ")) {
        // parsed below
      }
    }

    console.log(`commit ${current}`);
    console.log(`Date: ${timestampVal}`);
    console.log(`Message: ${messageVal}`);

    // Get parent
    const parentLine = content.split("\n").find(l => l.startsWith("parent: "));
    const parentHash = parentLine ? parentLine.substring("parent: ".length) : "NONE";
    current = parentHash === "NONE" ? "" : parentHash;
  }
}

function cmdStatus(): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  console.log("Staged files:");
  if (indexContent === "") {
    console.log("(none)");
  } else {
    const files = indexContent.split("\n");
    for (const file of files) {
      console.log(file);
    }
  }
}

function parseCommitFiles(content: string): Map<string, string> {
  const files = new Map<string, string>();
  const lines = content.split("\n");
  let inFiles = false;
  for (const line of lines) {
    if (line === "files:") {
      inFiles = true;
      continue;
    }
    if (inFiles && line.trim() !== "") {
      const spaceIdx = line.lastIndexOf(" ");
      const filename = line.substring(0, spaceIdx);
      const hash = line.substring(spaceIdx + 1);
      files.set(filename, hash);
    }
  }
  return files;
}

function cmdDiff(hash1: string, hash2: string): void {
  const commitPath1 = path.join(COMMITS_DIR, hash1);
  const commitPath2 = path.join(COMMITS_DIR, hash2);
  if (!fs.existsSync(commitPath1) || !fs.existsSync(commitPath2)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const files1 = parseCommitFiles(fs.readFileSync(commitPath1, "utf-8"));
  const files2 = parseCommitFiles(fs.readFileSync(commitPath2, "utf-8"));

  const allFiles = new Set([...files1.keys(), ...files2.keys()]);
  const sorted = Array.from(allFiles).sort();

  for (const file of sorted) {
    const h1 = files1.get(file);
    const h2 = files2.get(file);
    if (h1 === undefined && h2 !== undefined) {
      console.log(`Added: ${file}`);
    } else if (h1 !== undefined && h2 === undefined) {
      console.log(`Removed: ${file}`);
    } else if (h1 !== h2) {
      console.log(`Modified: ${file}`);
    }
  }
}

function cmdCheckout(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const content = fs.readFileSync(commitPath, "utf-8");
  const files = parseCommitFiles(content);
  for (const [filename, blobHash] of files) {
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
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  const entries = indexContent === "" ? [] : indexContent.split("\n");
  const idx = entries.indexOf(filename);
  if (idx === -1) {
    console.log("File not in index");
    process.exit(1);
  }
  entries.splice(idx, 1);
  fs.writeFileSync(INDEX_FILE, entries.length > 0 ? entries.join("\n") + "\n" : "");
}

function cmdShow(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }
  const content = fs.readFileSync(commitPath, "utf-8");
  let timestamp = "";
  let message = "";
  for (const line of content.split("\n")) {
    if (line.startsWith("timestamp: ")) {
      timestamp = line.substring("timestamp: ".length);
    } else if (line.startsWith("message: ")) {
      message = line.substring("message: ".length);
    }
  }
  const files = parseCommitFiles(content);
  const sortedFiles = Array.from(files.entries()).sort((a, b) => a[0].localeCompare(b[0]));

  console.log(`commit ${commitHash}`);
  console.log(`Date: ${timestamp}`);
  console.log(`Message: ${message}`);
  console.log("Files:");
  for (const [filename, hash] of sortedFiles) {
    console.log(`  ${filename} ${hash}`);
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
