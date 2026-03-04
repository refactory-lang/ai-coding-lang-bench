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
    if (!fs.existsSync(INDEX_FILE))
        return [];
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
    const data = fs.readFileSync(filename);
    const hash = miniHash(data);
    fs.writeFileSync(path.join(OBJECTS_DIR, hash), data);
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
    const fileLines = [];
    for (const f of sortedFiles) {
        const data = fs.readFileSync(f);
        const hash = miniHash(data);
        fileLines.push(`${f} ${hash}`);
    }
    const commitContent = `parent: ${parent}\n` +
        `timestamp: ${timestamp}\n` +
        `message: ${message}\n` +
        `files:\n` +
        fileLines.join("\n") +
        "\n";
    const commitHash = miniHash(Buffer.from(commitContent, "utf-8"));
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
        for (const f of entries) {
            console.log(f);
        }
    }
}
function parseCommit(hash) {
    const commitPath = path.join(COMMITS_DIR, hash);
    if (!fs.existsSync(commitPath)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    const content = fs.readFileSync(commitPath, "utf-8");
    const lines = content.split("\n");
    let parent = "";
    let timestamp = "";
    let message = "";
    const files = [];
    let inFiles = false;
    for (const line of lines) {
        if (inFiles) {
            if (line.trim() !== "") {
                const parts = line.split(" ");
                files.push([parts[0], parts[1]]);
            }
        }
        else if (line.startsWith("parent: ")) {
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
    }
    return { parent, timestamp, message, files };
}
function cmdDiff(hash1, hash2) {
    const c1 = parseCommit(hash1);
    const c2 = parseCommit(hash2);
    const map1 = new Map(c1.files);
    const map2 = new Map(c2.files);
    const allFiles = new Set([...map1.keys(), ...map2.keys()]);
    const sorted = [...allFiles].sort();
    for (const f of sorted) {
        const h1 = map1.get(f);
        const h2 = map2.get(f);
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
function cmdCheckout(hash) {
    const commit = parseCommit(hash);
    for (const [filename, blobHash] of commit.files) {
        const blobPath = path.join(OBJECTS_DIR, blobHash);
        const content = fs.readFileSync(blobPath);
        fs.writeFileSync(filename, content);
    }
    fs.writeFileSync(HEAD_FILE, hash);
    writeIndex([]);
    console.log(`Checked out ${hash}`);
}
function cmdReset(hash) {
    // Verify commit exists
    const commitPath = path.join(COMMITS_DIR, hash);
    if (!fs.existsSync(commitPath)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    fs.writeFileSync(HEAD_FILE, hash);
    writeIndex([]);
    console.log(`Reset to ${hash}`);
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
function cmdShow(hash) {
    const commit = parseCommit(hash);
    console.log(`commit ${hash}`);
    console.log(`Date: ${commit.timestamp}`);
    console.log(`Message: ${commit.message}`);
    console.log("Files:");
    const sorted = [...commit.files].sort((a, b) => a[0].localeCompare(b[0]));
    for (const [filename, blobHash] of sorted) {
        console.log(`  ${filename} ${blobHash}`);
    }
}
function cmdLog() {
    const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    if (head === "") {
        console.log("No commits");
        return;
    }
    let current = head;
    while (current) {
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
