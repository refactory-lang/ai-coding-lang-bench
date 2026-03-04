import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;

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
        Path file = Paths.get(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }
        byte[] content = Files.readAllBytes(file);
        String hash = miniHash(content);
        Files.write(OBJECTS_DIR.resolve(hash), content);

        // Read current index entries
        List<String> entries = readIndex();
        if (!entries.contains(filename)) {
            entries.add(filename);
            Files.write(INDEX_FILE, (String.join("\n", entries) + "\n").getBytes());
        }
    }

    static void doCommit(String message) throws Exception {
        List<String> entries = readIndex();
        if (entries.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String parent = new String(Files.readAllBytes(HEAD_FILE)).trim();
        if (parent.isEmpty()) {
            parent = "NONE";
        }

        long timestamp = System.currentTimeMillis() / 1000;

        // Sort filenames
        Collections.sort(entries);

        // Build file entries with their blob hashes
        StringBuilder filesSection = new StringBuilder();
        for (String filename : entries) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String hash = miniHash(content);
            filesSection.append(filename).append(" ").append(hash).append("\n");
        }

        String commitContent = "parent: " + parent + "\n"
                + "timestamp: " + timestamp + "\n"
                + "message: " + message + "\n"
                + "files:\n"
                + filesSection.toString();

        String commitHash = miniHash(commitContent.getBytes());
        Files.write(COMMITS_DIR.resolve(commitHash), commitContent.getBytes());
        Files.write(HEAD_FILE, commitHash.getBytes());
        // Clear index
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    static void doLog() throws Exception {
        String head = new String(Files.readAllBytes(HEAD_FILE)).trim();
        if (head.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = head;
        while (!current.equals("NONE") && !current.isEmpty()) {
            Path commitFile = COMMITS_DIR.resolve(current);
            String content = new String(Files.readAllBytes(commitFile));
            String[] lines = content.split("\n");

            String parent = "";
            String timestamp = "";
            String message = "";

            for (String line : lines) {
                if (line.startsWith("parent: ")) {
                    parent = line.substring(8);
                } else if (line.startsWith("timestamp: ")) {
                    timestamp = line.substring(11);
                } else if (line.startsWith("message: ")) {
                    message = line.substring(9);
                }
            }

            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);
            System.out.println();

            current = parent;
        }
    }

    static void doStatus() throws Exception {
        List<String> entries = readIndex();
        System.out.println("Staged files:");
        if (entries.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String e : entries) {
                System.out.println(e);
            }
        }
    }

    static Map<String, String> parseCommitFiles(String commitHash) throws Exception {
        Path commitFile = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitFile)) {
            return null;
        }
        String content = new String(Files.readAllBytes(commitFile));
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : content.split("\n")) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.isEmpty()) {
                String[] parts = line.split(" ", 2);
                files.put(parts[0], parts[1]);
            }
        }
        return files;
    }

    static void doDiff(String commit1, String commit2) throws Exception {
        Map<String, String> files1 = parseCommitFiles(commit1);
        Map<String, String> files2 = parseCommitFiles(commit2);
        if (files1 == null || files2 == null) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Set<String> allFiles = new TreeSet<>();
        allFiles.addAll(files1.keySet());
        allFiles.addAll(files2.keySet());
        for (String f : allFiles) {
            String h1 = files1.get(f);
            String h2 = files2.get(f);
            if (h1 == null) {
                System.out.println("Added: " + f);
            } else if (h2 == null) {
                System.out.println("Removed: " + f);
            } else if (!h1.equals(h2)) {
                System.out.println("Modified: " + f);
            }
        }
    }

    static void doCheckout(String commitHash) throws Exception {
        Path commitFile = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files = parseCommitFiles(commitHash);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blob = Files.readAllBytes(OBJECTS_DIR.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blob);
        }
        Files.write(HEAD_FILE, commitHash.getBytes());
        Files.write(INDEX_FILE, new byte[0]);
        System.out.println("Checked out " + commitHash);
    }

    static void doReset(String commitHash) throws Exception {
        Path commitFile = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.write(HEAD_FILE, commitHash.getBytes());
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
        if (entries.isEmpty()) {
            Files.write(INDEX_FILE, new byte[0]);
        } else {
            Files.write(INDEX_FILE, (String.join("\n", entries) + "\n").getBytes());
        }
    }

    static void doShow(String commitHash) throws Exception {
        Path commitFile = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = new String(Files.readAllBytes(commitFile));
        String timestamp = "";
        String message = "";
        for (String line : content.split("\n")) {
            if (line.startsWith("timestamp: ")) {
                timestamp = line.substring(11);
            } else if (line.startsWith("message: ")) {
                message = line.substring(9);
            }
        }
        Map<String, String> files = parseCommitFiles(commitHash);
        System.out.println("commit " + commitHash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : files.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    static List<String> readIndex() throws Exception {
        if (!Files.exists(INDEX_FILE)) {
            return new ArrayList<>();
        }
        String content = new String(Files.readAllBytes(INDEX_FILE)).trim();
        if (content.isEmpty()) {
            return new ArrayList<>();
        }
        return new ArrayList<>(Arrays.asList(content.split("\n")));
    }

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }
}
