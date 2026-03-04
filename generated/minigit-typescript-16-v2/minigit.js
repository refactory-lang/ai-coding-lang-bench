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
    for (const b of data) {
        h = h ^ BigInt(b);
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
    const files = index.split("\n").sort();
    const head = fs.readFileSync(HEAD_FILE, "utf-8").trim();
    const parent = head === "" ? "NONE" : head;
    const timestamp = Math.floor(Date.now() / 1000);
    let commitContent = `parent: ${parent}\ntimestamp: ${timestamp}\nmessage: ${message}\nfiles:\n`;
    for (const f of files) {
        const content = fs.readFileSync(f);
        const hash = miniHash(content);
        commitContent += `${f} ${hash}\n`;
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
    while (current !== "" && current !== "NONE") {
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
        current = parentVal === "NONE" ? "" : parentVal;
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
    const files = new Map();
    let inFiles = false;
    for (const line of lines) {
        if (inFiles) {
            if (line.trim() !== "") {
                const parts = line.split(" ");
                files.set(parts[0], parts[1]);
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
    const allFiles = new Set();
    for (const f of c1.files.keys())
        allFiles.add(f);
    for (const f of c2.files.keys())
        allFiles.add(f);
    const sorted = Array.from(allFiles).sort();
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
function cmdCheckout(hash) {
    const commit = parseCommit(hash);
    for (const [filename, blobHash] of commit.files) {
        const blobContent = fs.readFileSync(path.join(OBJECTS_DIR, blobHash));
        fs.writeFileSync(filename, blobContent);
    }
    fs.writeFileSync(HEAD_FILE, hash);
    fs.writeFileSync(INDEX_FILE, "");
    console.log(`Checked out ${hash}`);
}
function cmdReset(hash) {
    const commitPath = path.join(COMMITS_DIR, hash);
    if (!fs.existsSync(commitPath)) {
        console.log("Invalid commit");
        process.exit(1);
    }
    fs.writeFileSync(HEAD_FILE, hash);
    fs.writeFileSync(INDEX_FILE, "");
    console.log(`Reset to ${hash}`);
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
function cmdShow(hash) {
    const commit = parseCommit(hash);
    console.log(`commit ${hash}`);
    console.log(`Date: ${commit.timestamp}`);
    console.log(`Message: ${commit.message}`);
    console.log("Files:");
    const sorted = Array.from(commit.files.keys()).sort();
    for (const f of sorted) {
        console.log(`  ${f} ${commit.files.get(f)}`);
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
    case "log":
        cmdLog();
        break;
    case "status":
        cmdStatus();
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
