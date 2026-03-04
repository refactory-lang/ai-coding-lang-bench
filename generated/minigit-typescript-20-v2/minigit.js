"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const fs = require("fs");
const path = require("path");
const MINIGIT_DIR = ".minigit";
const OBJECTS_DIR = path.join(MINIGIT_DIR, "objects");
const COMMITS_DIR = path.join(MINIGIT_DIR, "commits");
const INDEX_FILE = path.join(MINIGIT_DIR, "index");
const HEAD_FILE = path.join(MINIGIT_DIR, "HEAD");
function miniHash(data) {
    let h = BigInt("1469598103934665603");
    const mod = BigInt(1) << BigInt(64);
    const mul = BigInt("1099511628211");
    for (let i = 0; i < data.length; i++) {
        h = h ^ BigInt(data[i]);
        h = (h * mul) % mod;
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
    const index = fs.readFileSync(INDEX_FILE, "utf-8");
    const entries = index.trim() === "" ? [] : index.trim().split("\n");
    if (!entries.includes(filename)) {
        entries.push(filename);
        fs.writeFileSync(INDEX_FILE, entries.join("\n") + "\n");
    }
}
function cmdCommit(message) {
    const index = fs.readFileSync(INDEX_FILE, "utf-8").trim();
    if (index === "") {
        console.log("Nothing to commit");
        process.exit(1);
    }
    const filenames = index.split("\n").sort();
    const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    const parent = head === "" ? "NONE" : head;
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
function cmdLog() {
    let current = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    if (current === "") {
        console.log("No commits");
        return;
    }
    let first = true;
    while (current !== "" && current !== "NONE") {
        const commitFile = path.join(COMMITS_DIR, current);
        const content = fs.readFileSync(commitFile, "utf-8");
        const lines = content.split("\n");
        let timestamp = "";
        let message = "";
        for (const line of lines) {
            if (line.startsWith("timestamp: ")) {
                timestamp = line.substring("timestamp: ".length);
            }
            else if (line.startsWith("message: ")) {
                message = line.substring("message: ".length);
            }
        }
        if (!first) {
            console.log("");
        }
        console.log(`commit ${current}`);
        console.log(`Date: ${timestamp}`);
        console.log(`Message: ${message}`);
        first = false;
        // Get parent
        const parentLine = lines.find((l) => l.startsWith("parent: "));
        const parent = parentLine ? parentLine.substring("parent: ".length) : "NONE";
        current = parent === "NONE" ? "" : parent;
    }
}
function cmdStatus() {
    const index = fs.readFileSync(INDEX_FILE, "utf-8").trim();
    console.log("Staged files:");
    if (index === "") {
        console.log("(none)");
    }
    else {
        const entries = index.split("\n");
        for (const e of entries) {
            console.log(e);
        }
    }
}
function parseCommitFiles(content) {
    const files = new Map();
    const lines = content.split("\n");
    let inFiles = false;
    for (const line of lines) {
        if (line === "files:") {
            inFiles = true;
            continue;
        }
        if (inFiles && line.trim() !== "") {
            const spaceIdx = line.lastIndexOf(" ");
            const fname = line.substring(0, spaceIdx);
            const hash = line.substring(spaceIdx + 1);
            files.set(fname, hash);
        }
    }
    return files;
}
function cmdDiff(hash1, hash2) {
    const commitFile1 = path.join(COMMITS_DIR, hash1);
    const commitFile2 = path.join(COMMITS_DIR, hash2);
    if (!fs.existsSync(commitFile1) || !fs.existsSync(commitFile2)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const files1 = parseCommitFiles(fs.readFileSync(commitFile1, "utf-8"));
    const files2 = parseCommitFiles(fs.readFileSync(commitFile2, "utf-8"));
    const allFiles = new Set([...files1.keys(), ...files2.keys()]);
    const sorted = Array.from(allFiles).sort();
    for (const fname of sorted) {
        const h1 = files1.get(fname);
        const h2 = files2.get(fname);
        if (h1 === undefined && h2 !== undefined) {
            console.log(`Added: ${fname}`);
        }
        else if (h1 !== undefined && h2 === undefined) {
            console.log(`Removed: ${fname}`);
        }
        else if (h1 !== h2) {
            console.log(`Modified: ${fname}`);
        }
    }
}
function cmdCheckout(commitHash) {
    const commitFile = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitFile)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const content = fs.readFileSync(commitFile, "utf-8");
    const files = parseCommitFiles(content);
    for (const [fname, blobHash] of files) {
        const blobContent = fs.readFileSync(path.join(OBJECTS_DIR, blobHash));
        fs.writeFileSync(fname, blobContent);
    }
    fs.writeFileSync(HEAD_FILE, commitHash);
    fs.writeFileSync(INDEX_FILE, "");
    console.log(`Checked out ${commitHash}`);
}
function cmdReset(commitHash) {
    const commitFile = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitFile)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    fs.writeFileSync(HEAD_FILE, commitHash);
    fs.writeFileSync(INDEX_FILE, "");
    console.log(`Reset to ${commitHash}`);
}
function cmdRm(filename) {
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
function cmdShow(commitHash) {
    const commitFile = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitFile)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const content = fs.readFileSync(commitFile, "utf-8");
    const lines = content.split("\n");
    let timestamp = "";
    let message = "";
    for (const line of lines) {
        if (line.startsWith("timestamp: ")) {
            timestamp = line.substring("timestamp: ".length);
        }
        else if (line.startsWith("message: ")) {
            message = line.substring("message: ".length);
        }
    }
    const files = parseCommitFiles(content);
    const sortedFiles = Array.from(files.entries()).sort((a, b) => a[0].localeCompare(b[0]));
    console.log(`commit ${commitHash}`);
    console.log(`Date: ${timestamp}`);
    console.log(`Message: ${message}`);
    console.log("Files:");
    for (const [fname, hash] of sortedFiles) {
        console.log(`  ${fname} ${hash}`);
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
