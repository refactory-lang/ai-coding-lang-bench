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
function cmdLog() {
    const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    if (head.length === 0) {
        console.log("No commits");
        return;
    }
    let current = head;
    while (current && current !== "NONE") {
        const commitPath = path.join(COMMITS_DIR, current);
        const content = fs.readFileSync(commitPath, "utf-8");
        const lines = content.split("\n");
        let ts = "";
        let msg = "";
        for (const line of lines) {
            if (line.startsWith("timestamp: "))
                ts = line.substring(11);
            if (line.startsWith("message: "))
                msg = line.substring(9);
        }
        console.log(`commit ${current}`);
        console.log(`Date: ${ts}`);
        console.log(`Message: ${msg}`);
        console.log("");
        let parent = null;
        for (const line of lines) {
            if (line.startsWith("parent: ")) {
                parent = line.substring(8);
                break;
            }
        }
        current = parent === "NONE" ? null : parent;
    }
}
function cmdStatus() {
    const indexContent = fs.readFileSync(INDEX_FILE, "utf-8");
    const files = indexContent.split("\n").filter((l) => l.length > 0);
    console.log("Staged files:");
    if (files.length === 0) {
        console.log("(none)");
    }
    else {
        for (const f of files) {
            console.log(f);
        }
    }
}
function parseCommitFiles(content) {
    const lines = content.split("\n");
    const files = new Map();
    let inFiles = false;
    for (const line of lines) {
        if (line === "files:") {
            inFiles = true;
            continue;
        }
        if (inFiles && line.length > 0) {
            const spaceIdx = line.lastIndexOf(" ");
            files.set(line.substring(0, spaceIdx), line.substring(spaceIdx + 1));
        }
    }
    return files;
}
function cmdDiff(hash1, hash2) {
    const path1 = path.join(COMMITS_DIR, hash1);
    const path2 = path.join(COMMITS_DIR, hash2);
    if (!fs.existsSync(path1) || !fs.existsSync(path2)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const files1 = parseCommitFiles(fs.readFileSync(path1, "utf-8"));
    const files2 = parseCommitFiles(fs.readFileSync(path2, "utf-8"));
    const allFiles = new Set([...files1.keys(), ...files2.keys()]);
    const sorted = Array.from(allFiles).sort();
    for (const f of sorted) {
        const h1 = files1.get(f);
        const h2 = files2.get(f);
        if (!h1 && h2) {
            console.log(`Added: ${f}`);
        }
        else if (h1 && !h2) {
            console.log(`Removed: ${f}`);
        }
        else if (h1 && h2 && h1 !== h2) {
            console.log(`Modified: ${f}`);
        }
    }
}
function cmdCheckout(commitHash) {
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
function cmdReset(commitHash) {
    const commitPath = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitPath)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    fs.writeFileSync(HEAD_FILE, commitHash);
    fs.writeFileSync(INDEX_FILE, "");
    console.log(`Reset to ${commitHash}`);
}
function cmdRm(filename) {
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
function cmdShow(commitHash) {
    const commitPath = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitPath)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const content = fs.readFileSync(commitPath, "utf-8");
    const contentLines = content.split("\n");
    let ts = "";
    let msg = "";
    for (const line of contentLines) {
        if (line.startsWith("timestamp: "))
            ts = line.substring(11);
        if (line.startsWith("message: "))
            msg = line.substring(9);
    }
    const files = parseCommitFiles(content);
    const sorted = Array.from(files.keys()).sort();
    console.log(`commit ${commitHash}`);
    console.log(`Date: ${ts}`);
    console.log(`Message: ${msg}`);
    console.log("Files:");
    for (const f of sorted) {
        console.log(`  ${f} ${files.get(f)}`);
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
            if (args[1] === "-m" && args.length >= 3) {
                cmdCommit(args[2]);
            }
            else {
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
