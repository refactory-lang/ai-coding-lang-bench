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
    let h = 1469598103934665603n;
    const mod = 1n << 64n;
    for (const b of data) {
        h = h ^ BigInt(b);
        h = (h * 1099511628211n) % mod;
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
    let commitContent = `parent: ${parent}\n`;
    commitContent += `timestamp: ${timestamp}\n`;
    commitContent += `message: ${message}\n`;
    commitContent += `files:\n`;
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
function cmdStatus() {
    const index = fs.readFileSync(INDEX_FILE, "utf-8").trim();
    console.log("Staged files:");
    if (index === "") {
        console.log("(none)");
    }
    else {
        for (const f of index.split("\n")) {
            console.log(f);
        }
    }
}
function parseCommit(hash) {
    const content = fs.readFileSync(path.join(COMMITS_DIR, hash), "utf-8");
    const lines = content.split("\n");
    let parent = "";
    let timestamp = "";
    let message = "";
    const files = [];
    let inFiles = false;
    for (const line of lines) {
        if (line.startsWith("parent: ")) {
            parent = line.substring(8);
            inFiles = false;
        }
        else if (line.startsWith("timestamp: ")) {
            timestamp = line.substring(11);
            inFiles = false;
        }
        else if (line.startsWith("message: ")) {
            message = line.substring(9);
            inFiles = false;
        }
        else if (line === "files:") {
            inFiles = true;
        }
        else if (inFiles && line.trim() !== "") {
            const idx = line.lastIndexOf(" ");
            files.push([line.substring(0, idx), line.substring(idx + 1)]);
        }
    }
    return { parent, timestamp, message, files };
}
function cmdDiff(hash1, hash2) {
    if (!fs.existsSync(path.join(COMMITS_DIR, hash1)) || !fs.existsSync(path.join(COMMITS_DIR, hash2))) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const c1 = parseCommit(hash1);
    const c2 = parseCommit(hash2);
    const map1 = new Map(c1.files);
    const map2 = new Map(c2.files);
    const allFiles = new Set([...map1.keys(), ...map2.keys()]);
    const sorted = [...allFiles].sort();
    for (const f of sorted) {
        const h1 = map1.get(f);
        const h2 = map2.get(f);
        if (h1 === undefined && h2 !== undefined)
            console.log(`Added: ${f}`);
        else if (h1 !== undefined && h2 === undefined)
            console.log(`Removed: ${f}`);
        else if (h1 !== h2)
            console.log(`Modified: ${f}`);
    }
}
function cmdCheckout(commitHash) {
    if (!fs.existsSync(path.join(COMMITS_DIR, commitHash))) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const commit = parseCommit(commitHash);
    for (const [filename, blobHash] of commit.files) {
        const content = fs.readFileSync(path.join(OBJECTS_DIR, blobHash));
        fs.writeFileSync(filename, content);
    }
    fs.writeFileSync(HEAD_FILE, commitHash);
    fs.writeFileSync(INDEX_FILE, "");
    console.log(`Checked out ${commitHash}`);
}
function cmdReset(commitHash) {
    if (!fs.existsSync(path.join(COMMITS_DIR, commitHash))) {
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
    if (!fs.existsSync(path.join(COMMITS_DIR, commitHash))) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const commit = parseCommit(commitHash);
    console.log(`commit ${commitHash}`);
    console.log(`Date: ${commit.timestamp}`);
    console.log(`Message: ${commit.message}`);
    console.log("Files:");
    const sorted = [...commit.files].sort((a, b) => a[0].localeCompare(b[0]));
    for (const [filename, blobHash] of sorted) {
        console.log(`  ${filename} ${blobHash}`);
    }
}
function cmdLog() {
    let current = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    if (current === "") {
        console.log("No commits");
        return;
    }
    while (current !== "" && current !== "NONE") {
        const commitContent = fs.readFileSync(path.join(COMMITS_DIR, current), "utf-8");
        const lines = commitContent.split("\n");
        let timestamp = "";
        let message = "";
        let parent = "";
        for (const line of lines) {
            if (line.startsWith("timestamp: "))
                timestamp = line.substring(11);
            else if (line.startsWith("message: "))
                message = line.substring(9);
            else if (line.startsWith("parent: "))
                parent = line.substring(8);
        }
        console.log(`commit ${current}`);
        console.log(`Date: ${timestamp}`);
        console.log(`Message: ${message}`);
        console.log("");
        current = parent === "NONE" ? "" : parent;
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
