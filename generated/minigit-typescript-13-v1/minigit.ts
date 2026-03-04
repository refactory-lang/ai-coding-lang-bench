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

    // Get parent
    const parentLine = lines.find((l) => l.startsWith("parent: "));
    current = parentLine ? parentLine.substring("parent: ".length) : "NONE";
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
    case "log":
      cmdLog();
      break;
    default:
      console.log(`Unknown command: ${command}`);
      process.exit(1);
  }
}

main();
