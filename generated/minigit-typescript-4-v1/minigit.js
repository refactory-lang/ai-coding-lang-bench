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
    for (let i = 0; i < data.length; i++) {
        h = h ^ BigInt(data[i]);
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
    const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
    const lines = indexContent.split("\n").filter((l) => l.length > 0);
    if (!lines.includes(filename)) {
        lines.push(filename);
        fs.writeFileSync(INDEX_FILE, lines.join("\n") + "\n");
    }
}
function cmdCommit(message) {
    const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
    const files = indexContent.split("\n").filter((l) => l.length > 0);
    if (files.length === 0) {
        console.log("Nothing to commit");
        process.exit(1);
    }
    const headContent = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    const parent = headContent.length > 0 ? headContent : "NONE";
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
function cmdLog() {
    const headContent = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    if (headContent.length === 0) {
        console.log("No commits");
        return;
    }
    let current = headContent;
    while (current && current !== "NONE") {
        const commitPath = path.join(COMMITS_DIR, current);
        const content = fs.readFileSync(commitPath, "utf-8");
        const lines = content.split("\n");
        let parentVal = "";
        let timestamp = "";
        let message = "";
        for (const line of lines) {
            if (line.startsWith("parent: "))
                parentVal = line.substring(8);
            else if (line.startsWith("timestamp: "))
                timestamp = line.substring(11);
            else if (line.startsWith("message: "))
                message = line.substring(9);
        }
        console.log(`commit ${current}`);
        console.log(`Date: ${timestamp}`);
        console.log(`Message: ${message}`);
        console.log("");
        current = parentVal === "NONE" ? null : parentVal;
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
