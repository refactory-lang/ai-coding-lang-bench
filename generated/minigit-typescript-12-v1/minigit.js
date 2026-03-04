var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));

// minigit.ts
var fs = __toESM(require("fs"));
var path = __toESM(require("path"));
var MINIGIT_DIR = ".minigit";
var OBJECTS_DIR = path.join(MINIGIT_DIR, "objects");
var COMMITS_DIR = path.join(MINIGIT_DIR, "commits");
var INDEX_FILE = path.join(MINIGIT_DIR, "index");
var HEAD_FILE = path.join(MINIGIT_DIR, "HEAD");
function miniHash(data) {
  let h = BigInt("1469598103934665603");
  const mod = BigInt(1) << BigInt(64);
  const mul = BigInt("1099511628211");
  for (let i = 0; i < data.length; i++) {
    h = h ^ BigInt(data[i]);
    h = h * mul % mod;
  }
  return h.toString(16).padStart(16, "0");
}
function cmdInit() {
  if (fs.existsSync(MINIGIT_DIR)) {
    console.log("Repository already initialized");
    return;
  }
  fs.mkdirSync(OBJECTS_DIR, { recursive: true });
  fs.mkdirSync(COMMITS_DIR, { recursive: true });
  fs.writeFileSync(INDEX_FILE, "");
  fs.writeFileSync(HEAD_FILE, "");
}
function cmdAdd(filename) {
  if (!fs.existsSync(filename)) {
    console.log("File not found");
    process.exit(1);
  }
  const content = fs.readFileSync(filename);
  const hash = miniHash(content);
  fs.writeFileSync(path.join(OBJECTS_DIR, hash), content);
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
  const entries = indexContent.trim() === "" ? [] : indexContent.trim().split("\n");
  if (!entries.includes(filename)) {
    entries.push(filename);
    fs.writeFileSync(INDEX_FILE, entries.join("\n") + "\n");
  }
}
function cmdCommit(message) {
  const indexContent = fs.readFileSync(INDEX_FILE, "utf-8").trim();
  if (indexContent === "") {
    console.log("Nothing to commit");
    process.exit(1);
  }
  const files = indexContent.split("\n").sort();
  const headContent = fs.readFileSync(HEAD_FILE, "utf-8").trim();
  const parent = headContent === "" ? "NONE" : headContent;
  const timestamp = Math.floor(Date.now() / 1e3);
  let commitContent = `parent: ${parent}
`;
  commitContent += `timestamp: ${timestamp}
`;
  commitContent += `message: ${message}
`;
  commitContent += `files:
`;
  for (const file of files) {
    const content = fs.readFileSync(file);
    const hash = miniHash(content);
    commitContent += `${file} ${hash}
`;
  }
  const commitHash = miniHash(Buffer.from(commitContent));
  fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
  fs.writeFileSync(HEAD_FILE, commitHash);
  fs.writeFileSync(INDEX_FILE, "");
  console.log(`Committed ${commitHash}`);
}
function cmdLog() {
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
      }
    }
    console.log(`commit ${current}`);
    console.log(`Date: ${timestampVal}`);
    console.log(`Message: ${messageVal}`);
    const parentLine = content.split("\n").find((l) => l.startsWith("parent: "));
    const parentHash = parentLine ? parentLine.substring("parent: ".length) : "NONE";
    current = parentHash === "NONE" ? "" : parentHash;
  }
}
function main() {
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
    case "log":
      cmdLog();
      break;
    default:
      console.log(`Unknown command: ${command}`);
      process.exit(1);
  }
}
main();
