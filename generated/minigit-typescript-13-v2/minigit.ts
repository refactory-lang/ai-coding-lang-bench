import * as fs from "fs";
import * as path from "path";

const MINIGIT_DIR = ".minigit";
const OBJECTS_DIR = path.join(MINIGIT_DIR, "objects");
const COMMITS_DIR = path.join(MINIGIT_DIR, "commits");
const INDEX_FILE = path.join(MINIGIT_DIR, "index");
const HEAD_FILE = path.join(MINIGIT_DIR, "HEAD");

function miniHash(data: Buffer): string {
  let h = BigInt("1469598103934665603");
  const mod = BigInt("18446744073709551616"); // 2^64
  const prime = BigInt("1099511628211");
  for (let i = 0; i < data.length; i++) {
    h = h ^ BigInt(data[i]);
    h = (h * prime) % mod;
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
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  if (indexContent.length === 0) {
    console.log("Nothing to commit");
    process.exit(1);
  }

  const filenames = indexContent.split("\n").sort();
  const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = head.length > 0 ? head : "NONE";
  const timestamp = Math.floor(Date.now() / 1000);

  let commitContent = `parent: ${parent}\ntimestamp: ${timestamp}\nmessage: ${message}\nfiles:\n`;
  for (const fname of filenames) {
    const content = fs.readFileSync(fname);
    const hash = miniHash(content);
    commitContent += `${fname} ${hash}\n`;
  }

  const commitHash = miniHash(Buffer.from(commitContent));
  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Committed ${commitHash}`);
}

function cmdStatus(): void {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  console.log("Staged files:");
  if (indexContent.length === 0) {
    console.log("(none)");
  } else {
    const files = indexContent.split("\n");
    for (const f of files) {
      console.log(f);
    }
  }
}

function cmdLog(): void {
  let current = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  if (current.length === 0) {
    console.log("No commits");
    return;
  }

  while (current.length > 0 && current !== "NONE") {
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

    const parentLine = lines.find((l) => l.startsWith("parent: "));
    current = parentLine ? parentLine.substring("parent: ".length) : "NONE";
  }
}

function parseCommitFiles(commitContent: string): Map<string, string> {
  const lines = commitContent.split("\n");
  const files = new Map<string, string>();
  let inFiles = false;
  for (const line of lines) {
    if (line === "files:") {
      inFiles = true;
      continue;
    }
    if (inFiles && line.length > 0) {
      const spaceIdx = line.lastIndexOf(" ");
      if (spaceIdx > 0) {
        files.set(line.substring(0, spaceIdx), line.substring(spaceIdx + 1));
      }
    }
  }
  return files;
}

function cmdDiff(commit1: string, commit2: string): void {
  const c1path = path.join(COMMITS_DIR, commit1);
  const c2path = path.join(COMMITS_DIR, commit2);

  if (!fs.existsSync(c1path) || !fs.existsSync(c2path)) {
    console.log("Invalid commit");
    process.exit(1);
  }

  const files1 = parseCommitFiles(fs.readFileSync(c1path, "utf-8"));
  const files2 = parseCommitFiles(fs.readFileSync(c2path, "utf-8"));

  const allFiles = new Set([...files1.keys(), ...files2.keys()]);
  const sorted = [...allFiles].sort();

  for (const fname of sorted) {
    const h1 = files1.get(fname);
    const h2 = files2.get(fname);
    if (h1 === undefined && h2 !== undefined) {
      console.log(`Added: ${fname}`);
    } else if (h1 !== undefined && h2 === undefined) {
      console.log(`Removed: ${fname}`);
    } else if (h1 !== h2) {
      console.log(`Modified: ${fname}`);
    }
  }
}

function cmdCheckout(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }

  const commitContent = fs.readFileSync(commitPath, "utf-8");
  const files = parseCommitFiles(commitContent);

  for (const [fname, blobHash] of files) {
    const blobPath = path.join(OBJECTS_DIR, blobHash);
    const content = fs.readFileSync(blobPath);
    fs.writeFileSync(fname, content);
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
  const idx = lines.indexOf(filename);
  if (idx === -1) {
    console.log("File not in index");
    process.exit(1);
  }
  lines.splice(idx, 1);
  fs.writeFileSync(INDEX_FILE, lines.length > 0 ? lines.join("\n") + "\n" : "");
}

function cmdShow(commitHash: string): void {
  const commitPath = path.join(COMMITS_DIR, commitHash);
  if (!fs.existsSync(commitPath)) {
    console.log("Invalid commit");
    process.exit(1);
  }

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

  const files = parseCommitFiles(content);
  const sortedFiles = [...files.entries()].sort((a, b) => a[0].localeCompare(b[0]));

  console.log(`commit ${commitHash}`);
  console.log(`Date: ${timestamp}`);
  console.log(`Message: ${message}`);
  console.log("Files:");
  for (const [fname, hash] of sortedFiles) {
    console.log(`  ${fname} ${hash}`);
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
      console.log(`Unknown command: ${command}`);
      process.exit(1);
  }
}

main();
