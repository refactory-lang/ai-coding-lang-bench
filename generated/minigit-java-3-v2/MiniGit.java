import java.io.*;
import java.nio.file.*;
import java.util.*;

public class MiniGit {

    static final Path MINIGIT_DIR = Paths.get(".minigit");
    static final Path OBJECTS_DIR = MINIGIT_DIR.resolve("objects");
    static final Path COMMITS_DIR = MINIGIT_DIR.resolve("commits");
    static final Path INDEX_FILE = MINIGIT_DIR.resolve("index");
    static final Path HEAD_FILE = MINIGIT_DIR.resolve("HEAD");

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }

        String command = args[0];

        switch (command) {
            case "init":
                doInit();
                break;
            case "add":
                if (args.length < 2) {
                    System.err.println("Usage: minigit add <file>");
                    System.exit(1);
                }
                doAdd(args[1]);
                break;
            case "commit":
                if (args.length < 3 || !args[1].equals("-m")) {
                    System.err.println("Usage: minigit commit -m \"<message>\"");
                    System.exit(1);
                }
                doCommit(args[2]);
                break;
            case "status":
                doStatus();
                break;
            case "log":
                doLog();
                break;
            case "diff":
                if (args.length < 3) {
                    System.err.println("Usage: minigit diff <commit1> <commit2>");
                    System.exit(1);
                }
                doDiff(args[1], args[2]);
                break;
            case "checkout":
                if (args.length < 2) {
                    System.err.println("Usage: minigit checkout <commit_hash>");
                    System.exit(1);
                }
                doCheckout(args[1]);
                break;
            case "reset":
                if (args.length < 2) {
                    System.err.println("Usage: minigit reset <commit_hash>");
                    System.exit(1);
                }
                doReset(args[1]);
                break;
            case "rm":
                if (args.length < 2) {
                    System.err.println("Usage: minigit rm <file>");
                    System.exit(1);
                }
                doRm(args[1]);
                break;
            case "show":
                if (args.length < 2) {
                    System.err.println("Usage: minigit show <commit_hash>");
                    System.exit(1);
                }
                doShow(args[1]);
                break;
            default:
                System.err.println("Unknown command: " + command);
                System.exit(1);
        }
    }

    static void doInit() throws Exception {
        if (Files.isDirectory(MINIGIT_DIR)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS_DIR);
        Files.createDirectories(COMMITS_DIR);
        Files.write(INDEX_FILE, new byte[0]);
        Files.write(HEAD_FILE, new byte[0]);
    }

    static void doAdd(String filename) throws Exception {
        Path filePath = Paths.get(filename);
        if (!Files.exists(filePath)) {
            System.out.println("File not found");
            System.exit(1);
        }

        byte[] content = Files.readAllBytes(filePath);
        String hash = miniHash(content);

        Files.write(OBJECTS_DIR.resolve(hash), content);

        // Read existing index entries
        List<String> entries = readIndex();
        if (!entries.contains(filename)) {
            entries.add(filename);
            writeIndex(entries);
        }
    }

    static void doCommit(String message) throws Exception {
        List<String> entries = readIndex();
        if (entries.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String head = readHead();
        String parent = head.isEmpty() ? "NONE" : head;

        long timestamp = System.currentTimeMillis() / 1000;

        // Sort filenames lexicographically
        Collections.sort(entries);

        // Build commit content
        StringBuilder sb = new StringBuilder();
        sb.append("parent: ").append(parent).append("\n");
        sb.append("timestamp: ").append(timestamp).append("\n");
        sb.append("message: ").append(message).append("\n");
        sb.append("files:\n");
        for (String filename : entries) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String blobHash = miniHash(content);
            sb.append(filename).append(" ").append(blobHash).append("\n");
        }

        String commitContent = sb.toString();
        String commitHash = miniHash(commitContent.getBytes("UTF-8"));

        Files.write(COMMITS_DIR.resolve(commitHash), commitContent.getBytes("UTF-8"));
        Files.write(HEAD_FILE, commitHash.getBytes("UTF-8"));

        // Clear index
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    static void doLog() throws Exception {
        String head = readHead();
        if (head.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = head;
        while (!current.isEmpty() && !current.equals("NONE")) {
            Path commitPath = COMMITS_DIR.resolve(current);
            if (!Files.exists(commitPath)) break;

            String content = new String(Files.readAllBytes(commitPath), "UTF-8");
            String[] lines = content.split("\n");

            String parentHash = "";
            String timestamp = "";
            String message = "";

            for (String line : lines) {
                if (line.startsWith("parent: ")) {
                    parentHash = line.substring("parent: ".length());
                } else if (line.startsWith("timestamp: ")) {
                    timestamp = line.substring("timestamp: ".length());
                } else if (line.startsWith("message: ")) {
                    message = line.substring("message: ".length());
                }
            }

            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);
            System.out.println();

            current = parentHash.equals("NONE") ? "" : parentHash;
        }
    }

    static void doStatus() throws Exception {
        List<String> entries = readIndex();
        System.out.println("Staged files:");
        if (entries.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String entry : entries) {
                System.out.println(entry);
            }
        }
    }

    static Map<String, String> parseCommitFiles(String commitContent) {
        Map<String, String> files = new LinkedHashMap<>();
        String[] lines = commitContent.split("\n");
        boolean inFiles = false;
        for (String line : lines) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.isEmpty()) {
                int spaceIdx = line.indexOf(' ');
                if (spaceIdx > 0) {
                    files.put(line.substring(0, spaceIdx), line.substring(spaceIdx + 1));
                }
            }
        }
        return files;
    }

    static void doDiff(String hash1, String hash2) throws Exception {
        Path commit1Path = COMMITS_DIR.resolve(hash1);
        Path commit2Path = COMMITS_DIR.resolve(hash2);
        if (!Files.exists(commit1Path) || !Files.exists(commit2Path)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        String content1 = new String(Files.readAllBytes(commit1Path), "UTF-8");
        String content2 = new String(Files.readAllBytes(commit2Path), "UTF-8");

        Map<String, String> files1 = parseCommitFiles(content1);
        Map<String, String> files2 = parseCommitFiles(content2);

        TreeSet<String> allFiles = new TreeSet<>();
        allFiles.addAll(files1.keySet());
        allFiles.addAll(files2.keySet());

        for (String file : allFiles) {
            String blob1 = files1.get(file);
            String blob2 = files2.get(file);
            if (blob1 == null) {
                System.out.println("Added: " + file);
            } else if (blob2 == null) {
                System.out.println("Removed: " + file);
            } else if (!blob1.equals(blob2)) {
                System.out.println("Modified: " + file);
            }
        }
    }

    static void doCheckout(String commitHash) throws Exception {
        Path commitPath = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        String content = new String(Files.readAllBytes(commitPath), "UTF-8");
        Map<String, String> files = parseCommitFiles(content);

        for (Map.Entry<String, String> entry : files.entrySet()) {
            String filename = entry.getKey();
            String blobHash = entry.getValue();
            byte[] blobContent = Files.readAllBytes(OBJECTS_DIR.resolve(blobHash));
            Files.write(Paths.get(filename), blobContent);
        }

        Files.write(HEAD_FILE, commitHash.getBytes("UTF-8"));
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Checked out " + commitHash);
    }

    static void doReset(String commitHash) throws Exception {
        Path commitPath = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Files.write(HEAD_FILE, commitHash.getBytes("UTF-8"));
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Reset to " + commitHash);
    }

    static void doRm(String filename) throws Exception {
        List<String> entries = readIndex();
        if (!entries.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        entries.remove(filename);
        writeIndex(entries);
    }

    static void doShow(String commitHash) throws Exception {
        Path commitPath = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        String content = new String(Files.readAllBytes(commitPath), "UTF-8");
        String[] lines = content.split("\n");

        String timestamp = "";
        String message = "";

        for (String line : lines) {
            if (line.startsWith("timestamp: ")) {
                timestamp = line.substring("timestamp: ".length());
            } else if (line.startsWith("message: ")) {
                message = line.substring("message: ".length());
            }
        }

        Map<String, String> files = parseCommitFiles(content);

        System.out.println("commit " + commitHash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        TreeSet<String> sortedFiles = new TreeSet<>(files.keySet());
        for (String file : sortedFiles) {
            System.out.println("  " + file + " " + files.get(file));
        }
    }

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h = h ^ (b & 0xFF);
            h = h * 1099511628211L; // Java long multiplication wraps at 2^64
        }
        return String.format("%016x", h);
    }

    static List<String> readIndex() throws Exception {
        List<String> entries = new ArrayList<>();
        if (Files.exists(INDEX_FILE)) {
            String content = new String(Files.readAllBytes(INDEX_FILE), "UTF-8").trim();
            if (!content.isEmpty()) {
                for (String line : content.split("\n")) {
                    String trimmed = line.trim();
                    if (!trimmed.isEmpty()) {
                        entries.add(trimmed);
                    }
                }
            }
        }
        return entries;
    }

    static void writeIndex(List<String> entries) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (String entry : entries) {
            sb.append(entry).append("\n");
        }
        Files.write(INDEX_FILE, sb.toString().getBytes("UTF-8"));
    }

    static String readHead() throws Exception {
        if (!Files.exists(HEAD_FILE)) return "";
        return new String(Files.readAllBytes(HEAD_FILE), "UTF-8").trim();
    }
}
