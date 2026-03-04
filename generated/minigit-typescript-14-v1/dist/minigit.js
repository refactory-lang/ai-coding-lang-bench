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
        case "log":
            cmdLog();
            break;
        default:
            console.log(`Unknown command: ${command}`);
            process.exit(1);
    }
}
main();
