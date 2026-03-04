import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;

public class MiniGit {

    private static final Path MINIGIT_DIR = Path.of(".minigit");
    private static final Path OBJECTS_DIR = MINIGIT_DIR.resolve("objects");
    private static final Path COMMITS_DIR = MINIGIT_DIR.resolve("commits");
    private static final Path INDEX_FILE = MINIGIT_DIR.resolve("index");
    private static final Path HEAD_FILE = MINIGIT_DIR.resolve("HEAD");

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }

        String command = args[0];
        switch (command) {
            case "init" -> doInit();
            case "add" -> {
                if (args.length < 2) {
                    System.err.println("Usage: minigit add <file>");
                    System.exit(1);
                }
                doAdd(args[1]);
            }
            case "commit" -> {
                if (args.length < 3 || !args[1].equals("-m")) {
                    System.err.println("Usage: minigit commit -m \"<message>\"");
                    System.exit(1);
                }
                doCommit(args[2]);
            }
            case "status" -> doStatus();
            case "log" -> doLog();
            case "diff" -> {
                if (args.length < 3) {
                    System.err.println("Usage: minigit diff <commit1> <commit2>");
                    System.exit(1);
                }
                doDiff(args[1], args[2]);
            }
            case "checkout" -> {
                if (args.length < 2) {
                    System.err.println("Usage: minigit checkout <commit_hash>");
                    System.exit(1);
                }
                doCheckout(args[1]);
            }
            case "reset" -> {
                if (args.length < 2) {
                    System.err.println("Usage: minigit reset <commit_hash>");
                    System.exit(1);
                }
                doReset(args[1]);
            }
            case "rm" -> {
                if (args.length < 2) {
                    System.err.println("Usage: minigit rm <file>");
                    System.exit(1);
                }
                doRm(args[1]);
            }
            case "show" -> {
                if (args.length < 2) {
                    System.err.println("Usage: minigit show <commit_hash>");
                    System.exit(1);
                }
                doShow(args[1]);
            }
            default -> {
                System.err.println("Unknown command: " + command);
                System.exit(1);
            }
        }
    }

    private static String miniHash(byte[] data) {
        long h = Long.parseUnsignedLong("1469598103934665603");
        for (byte b : data) {
            h ^= (b & 0xFF);
            h = Long.remainderUnsigned(Long.toUnsignedString(h * 1099511628211L).isEmpty() ? h * 1099511628211L : h * 1099511628211L, 0L);
        }
        return String.format("%016x", h);
    }

    // Correct miniHash using unsigned arithmetic
    private static String computeHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h = h ^ (b & 0xFF);
            h = h * 1099511628211L; // Java long overflow gives us mod 2^64 for free
        }
        return String.format("%016x", h);
    }

    private static void doInit() throws IOException {
        if (Files.isDirectory(MINIGIT_DIR)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS_DIR);
        Files.createDirectories(COMMITS_DIR);
        Files.writeString(INDEX_FILE, "");
        Files.writeString(HEAD_FILE, "");
    }

    private static void doAdd(String filename) throws IOException {
        Path file = Path.of(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }

        byte[] content = Files.readAllBytes(file);
        String hash = computeHash(content);

        // Store blob
        Path blobPath = OBJECTS_DIR.resolve(hash);
        Files.write(blobPath, content);

        // Update index
        List<String> indexLines = readIndex();
        if (!indexLines.contains(filename)) {
            indexLines.add(filename);
            Files.writeString(INDEX_FILE, String.join("\n", indexLines) + "\n");
        }
    }

    private static void doCommit(String message) throws Exception {
        List<String> indexLines = readIndex();
        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        // Sort filenames
        Collections.sort(indexLines);

        // Get parent
        String head = Files.readString(HEAD_FILE).trim();
        String parent = head.isEmpty() ? "NONE" : head;

        // Timestamp
        long timestamp = System.currentTimeMillis() / 1000;

        // Build file entries - hash each file's current content
        StringBuilder filesSection = new StringBuilder();
        for (String filename : indexLines) {
            Path filePath = Path.of(filename);
            byte[] content = Files.readAllBytes(filePath);
            String hash = computeHash(content);
            // Also ensure blob is stored
            Files.write(OBJECTS_DIR.resolve(hash), content);
            filesSection.append(filename).append(" ").append(hash).append("\n");
        }

        // Build commit content
        String commitContent = "parent: " + parent + "\n"
                + "timestamp: " + timestamp + "\n"
                + "message: " + message + "\n"
                + "files:\n"
                + filesSection.toString();

        // Hash commit
        String commitHash = computeHash(commitContent.getBytes());

        // Write commit file
        Files.writeString(COMMITS_DIR.resolve(commitHash), commitContent);

        // Update HEAD
        Files.writeString(HEAD_FILE, commitHash);

        // Clear index
        Files.writeString(INDEX_FILE, "");

        System.out.println("Committed " + commitHash);
    }

    private static void doLog() throws IOException {
        String head = Files.readString(HEAD_FILE).trim();
        if (head.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = head;
        while (!current.equals("NONE") && !current.isEmpty()) {
            Path commitFile = COMMITS_DIR.resolve(current);
            String content = Files.readString(commitFile);

            String parentHash = "";
            String timestamp = "";
            String message = "";

            for (String line : content.split("\n")) {
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

            current = parentHash;
        }
    }

    private static void doStatus() throws IOException {
        List<String> indexLines = readIndex();
        System.out.println("Staged files:");
        if (indexLines.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : indexLines) {
                System.out.println(f);
            }
        }
    }

    private static Map<String, String> parseCommitFiles(String commitContent) {
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : commitContent.split("\n")) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.isEmpty()) {
                String[] parts = line.split(" ", 2);
                if (parts.length == 2) {
                    files.put(parts[0], parts[1]);
                }
            }
        }
        return files;
    }

    private static void doDiff(String hash1, String hash2) throws IOException {
        Path c1 = COMMITS_DIR.resolve(hash1);
        Path c2 = COMMITS_DIR.resolve(hash2);
        if (!Files.exists(c1) || !Files.exists(c2)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Map<String, String> files1 = parseCommitFiles(Files.readString(c1));
        Map<String, String> files2 = parseCommitFiles(Files.readString(c2));

        Set<String> allFiles = new TreeSet<>();
        allFiles.addAll(files1.keySet());
        allFiles.addAll(files2.keySet());

        for (String f : allFiles) {
            String b1 = files1.get(f);
            String b2 = files2.get(f);
            if (b1 == null) {
                System.out.println("Added: " + f);
            } else if (b2 == null) {
                System.out.println("Removed: " + f);
            } else if (!b1.equals(b2)) {
                System.out.println("Modified: " + f);
            }
        }
    }

    private static void doCheckout(String commitHash) throws IOException {
        Path commitFile = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Map<String, String> files = parseCommitFiles(Files.readString(commitFile));
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] content = Files.readAllBytes(OBJECTS_DIR.resolve(entry.getValue()));
            Files.write(Path.of(entry.getKey()), content);
        }

        Files.writeString(HEAD_FILE, commitHash);
        Files.writeString(INDEX_FILE, "");
        System.out.println("Checked out " + commitHash);
    }

    private static void doReset(String commitHash) throws IOException {
        Path commitFile = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Files.writeString(HEAD_FILE, commitHash);
        Files.writeString(INDEX_FILE, "");
        System.out.println("Reset to " + commitHash);
    }

    private static void doRm(String filename) throws IOException {
        List<String> indexLines = readIndex();
        if (!indexLines.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        indexLines.remove(filename);
        if (indexLines.isEmpty()) {
            Files.writeString(INDEX_FILE, "");
        } else {
            Files.writeString(INDEX_FILE, String.join("\n", indexLines) + "\n");
        }
    }

    private static void doShow(String commitHash) throws IOException {
        Path commitFile = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        String content = Files.readString(commitFile);
        String timestamp = "";
        String message = "";
        for (String line : content.split("\n")) {
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
        for (Map.Entry<String, String> entry : files.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    private static List<String> readIndex() throws IOException {
        if (!Files.exists(INDEX_FILE)) {
            return new ArrayList<>();
        }
        String content = Files.readString(INDEX_FILE).trim();
        if (content.isEmpty()) {
            return new ArrayList<>();
        }
        return new ArrayList<>(Arrays.asList(content.split("\n")));
    }
}
