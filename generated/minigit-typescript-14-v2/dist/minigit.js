"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
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
function readIndex() {
    const content = fs.readFileSync(INDEX_FILE, "utf-8").trim();
    if (content === "")
        return [];
    return content.split("\n");
}
function writeIndex(entries) {
    fs.writeFileSync(INDEX_FILE, entries.length > 0 ? entries.join("\n") + "\n" : "");
}
function cmdAdd(filename) {
    if (!fs.existsSync(filename)) {
        console.log("File not found");
        process.exit(1);
    }
    const content = fs.readFileSync(filename);
    const hash = miniHash(content);
    fs.writeFileSync(path.join(OBJECTS_DIR, hash), content);
    const entries = readIndex();
    if (!entries.includes(filename)) {
        entries.push(filename);
        writeIndex(entries);
    }
}
function cmdCommit(message) {
    const entries = readIndex();
    if (entries.length === 0) {
        console.log("Nothing to commit");
        process.exit(1);
    }
    const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    const parent = head === "" ? "NONE" : head;
    const timestamp = Math.floor(Date.now() / 1000);
    const sortedFiles = [...entries].sort();
    const fileLines = sortedFiles
        .map((f) => {
        const content = fs.readFileSync(f);
        const hash = miniHash(content);
        return `${f} ${hash}`;
    })
        .join("\n");
    const commitContent = `parent: ${parent}\ntimestamp: ${timestamp}\nmessage: ${message}\nfiles:\n${fileLines}\n`;
    const commitHash = miniHash(Buffer.from(commitContent));
    fs.writeFileSync(path.join(COMMITS_DIR, commitHash), commitContent);
    fs.writeFileSync(HEAD_FILE, commitHash);
    writeIndex([]);
    console.log(`Committed ${commitHash}`);
}
function cmdStatus() {
    const entries = readIndex();
    console.log("Staged files:");
    if (entries.length === 0) {
        console.log("(none)");
    }
    else {
        for (const e of entries) {
            console.log(e);
        }
    }
}
function parseCommit(content) {
    const lines = content.split("\n");
    let parent = "NONE";
    let timestamp = "";
    let message = "";
    const files = new Map();
    let inFiles = false;
    for (const line of lines) {
        if (line.startsWith("parent: ")) {
            parent = line.substring(8);
        }
        else if (line.startsWith("timestamp: ")) {
            timestamp = line.substring(11);
        }
        else if (line.startsWith("message: ")) {
            message = line.substring(9);
        }
        else if (line === "files:") {
            inFiles = true;
        }
        else if (inFiles && line.trim() !== "") {
            const spaceIdx = line.indexOf(" ");
            if (spaceIdx !== -1) {
                files.set(line.substring(0, spaceIdx), line.substring(spaceIdx + 1));
            }
        }
    }
    return { parent, timestamp, message, files };
}
function cmdDiff(hash1, hash2) {
    const commitFile1 = path.join(COMMITS_DIR, hash1);
    const commitFile2 = path.join(COMMITS_DIR, hash2);
    if (!fs.existsSync(commitFile1) || !fs.existsSync(commitFile2)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const c1 = parseCommit(fs.readFileSync(commitFile1, "utf-8"));
    const c2 = parseCommit(fs.readFileSync(commitFile2, "utf-8"));
    const allFiles = new Set();
    for (const f of c1.files.keys())
        allFiles.add(f);
    for (const f of c2.files.keys())
        allFiles.add(f);
    const sorted = [...allFiles].sort();
    for (const f of sorted) {
        const h1 = c1.files.get(f);
        const h2 = c2.files.get(f);
        if (h1 === undefined && h2 !== undefined) {
            console.log(`Added: ${f}`);
        }
        else if (h1 !== undefined && h2 === undefined) {
            console.log(`Removed: ${f}`);
        }
        else if (h1 !== h2) {
            console.log(`Modified: ${f}`);
        }
    }
}
function cmdCheckout(commitHash) {
    const commitFile = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitFile)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const commit = parseCommit(fs.readFileSync(commitFile, "utf-8"));
    for (const [filename, blobHash] of commit.files) {
        const blobContent = fs.readFileSync(path.join(OBJECTS_DIR, blobHash));
        fs.writeFileSync(filename, blobContent);
    }
    fs.writeFileSync(HEAD_FILE, commitHash);
    writeIndex([]);
    console.log(`Checked out ${commitHash}`);
}
function cmdReset(commitHash) {
    const commitFile = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitFile)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    fs.writeFileSync(HEAD_FILE, commitHash);
    writeIndex([]);
    console.log(`Reset to ${commitHash}`);
}
function cmdRm(filename) {
    const entries = readIndex();
    const idx = entries.indexOf(filename);
    if (idx === -1) {
        console.log("File not in index");
        process.exit(1);
    }
    entries.splice(idx, 1);
    writeIndex(entries);
}
function cmdShow(commitHash) {
    const commitFile = path.join(COMMITS_DIR, commitHash);
    if (!fs.existsSync(commitFile)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const commit = parseCommit(fs.readFileSync(commitFile, "utf-8"));
    console.log(`commit ${commitHash}`);
    console.log(`Date: ${commit.timestamp}`);
    console.log(`Message: ${commit.message}`);
    console.log("Files:");
    const sortedFiles = [...commit.files.entries()].sort((a, b) => a[0].localeCompare(b[0]));
    for (const [filename, blobHash] of sortedFiles) {
        console.log(`  ${filename} ${blobHash}`);
    }
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
        let parentHash = "NONE";
        let timestamp = "";
        let message = "";
        for (const line of content.split("\n")) {
            if (line.startsWith("parent: "))
                parentHash = line.substring(8);
            else if (line.startsWith("timestamp: "))
                timestamp = line.substring(11);
            else if (line.startsWith("message: "))
                message = line.substring(9);
        }
        if (!first)
            console.log("");
        console.log(`commit ${current}`);
        console.log(`Date: ${timestamp}`);
        console.log(`Message: ${message}`);
        first = false;
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
