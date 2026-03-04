import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;

public class MiniGit {

    private static final Path MINIGIT = Paths.get(".minigit");
    private static final Path OBJECTS = MINIGIT.resolve("objects");
    private static final Path COMMITS = MINIGIT.resolve("commits");
    private static final Path INDEX = MINIGIT.resolve("index");
    private static final Path HEAD = MINIGIT.resolve("HEAD");

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }
        switch (args[0]) {
            case "init":
                init();
                break;
            case "add":
                if (args.length < 2) { System.err.println("Usage: minigit add <file>"); System.exit(1); }
                add(args[1]);
                break;
            case "commit":
                if (args.length < 3 || !args[1].equals("-m")) { System.err.println("Usage: minigit commit -m <msg>"); System.exit(1); }
                commit(args[2]);
                break;
            case "status":
                status();
                break;
            case "log":
                log();
                break;
            case "diff":
                if (args.length < 3) { System.err.println("Usage: minigit diff <c1> <c2>"); System.exit(1); }
                diff(args[1], args[2]);
                break;
            case "checkout":
                if (args.length < 2) { System.err.println("Usage: minigit checkout <hash>"); System.exit(1); }
                checkout(args[1]);
                break;
            case "reset":
                if (args.length < 2) { System.err.println("Usage: minigit reset <hash>"); System.exit(1); }
                reset(args[1]);
                break;
            case "rm":
                if (args.length < 2) { System.err.println("Usage: minigit rm <file>"); System.exit(1); }
                rm(args[1]);
                break;
            case "show":
                if (args.length < 2) { System.err.println("Usage: minigit show <hash>"); System.exit(1); }
                show(args[1]);
                break;
            default:
                System.err.println("Unknown command: " + args[0]);
                System.exit(1);
        }
    }

    private static void init() throws IOException {
        if (Files.isDirectory(MINIGIT)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS);
        Files.createDirectories(COMMITS);
        Files.writeString(INDEX, "");
        Files.writeString(HEAD, "");
    }

    private static void add(String filename) throws IOException {
        Path file = Paths.get(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }
        byte[] content = Files.readAllBytes(file);
        String hash = miniHash(content);
        Files.write(OBJECTS.resolve(hash), content);

        // Add to index if not already present
        List<String> lines = readLines(INDEX);
        if (!lines.contains(filename)) {
            lines.add(filename);
            Files.writeString(INDEX, String.join("\n", lines) + "\n");
        }
    }

    private static void commit(String message) throws Exception {
        List<String> indexLines = readLines(INDEX);
        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String parent = Files.readString(HEAD).trim();
        if (parent.isEmpty()) parent = "NONE";

        long timestamp = System.currentTimeMillis() / 1000;

        // Build file entries sorted
        List<String> sortedFiles = new ArrayList<>(indexLines);
        Collections.sort(sortedFiles);

        StringBuilder commitContent = new StringBuilder();
        commitContent.append("parent: ").append(parent).append("\n");
        commitContent.append("timestamp: ").append(timestamp).append("\n");
        commitContent.append("message: ").append(message).append("\n");
        commitContent.append("files:\n");
        for (String fname : sortedFiles) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String blobHash = miniHash(content);
            commitContent.append(fname).append(" ").append(blobHash).append("\n");
        }

        String commitStr = commitContent.toString();
        String commitHash = miniHash(commitStr.getBytes());

        Files.writeString(COMMITS.resolve(commitHash), commitStr);
        Files.writeString(HEAD, commitHash);
        Files.writeString(INDEX, "");

        System.out.println("Committed " + commitHash);
    }

    private static void log() throws IOException {
        String head = Files.readString(HEAD).trim();
        if (head.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = head;
        while (!current.equals("NONE") && !current.isEmpty()) {
            String content = Files.readString(COMMITS.resolve(current));
            String parent = "";
            String timestamp = "";
            String message = "";
            for (String line : content.split("\n")) {
                if (line.startsWith("parent: ")) parent = line.substring(8);
                else if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
                else if (line.startsWith("message: ")) message = line.substring(9);
            }
            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);
            System.out.println();
            current = parent;
        }
    }

    private static void status() throws IOException {
        List<String> lines = readLines(INDEX);
        System.out.println("Staged files:");
        if (lines.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : lines) {
                System.out.println(f);
            }
        }
    }

    private static void diff(String hash1, String hash2) throws IOException {
        Path c1 = COMMITS.resolve(hash1);
        Path c2 = COMMITS.resolve(hash2);
        if (!Files.exists(c1) || !Files.exists(c2)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files1 = parseCommitFiles(Files.readString(c1));
        Map<String, String> files2 = parseCommitFiles(Files.readString(c2));

        TreeSet<String> allFiles = new TreeSet<>();
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

    private static void checkout(String hash) throws IOException {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files = parseCommitFiles(Files.readString(commitPath));
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] content = Files.readAllBytes(OBJECTS.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), content);
        }
        Files.writeString(HEAD, hash);
        Files.writeString(INDEX, "");
        System.out.println("Checked out " + hash);
    }

    private static void reset(String hash) throws IOException {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.writeString(HEAD, hash);
        Files.writeString(INDEX, "");
        System.out.println("Reset to " + hash);
    }

    private static void rm(String filename) throws IOException {
        List<String> lines = readLines(INDEX);
        if (!lines.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        lines.remove(filename);
        if (lines.isEmpty()) {
            Files.writeString(INDEX, "");
        } else {
            Files.writeString(INDEX, String.join("\n", lines) + "\n");
        }
    }

    private static void show(String hash) throws IOException {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = Files.readString(commitPath);
        String timestamp = "";
        String message = "";
        for (String line : content.split("\n")) {
            if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
            else if (line.startsWith("message: ")) message = line.substring(9);
        }
        Map<String, String> files = parseCommitFiles(content);
        System.out.println("commit " + hash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : new TreeMap<>(files).entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    private static Map<String, String> parseCommitFiles(String content) {
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : content.split("\n")) {
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

    private static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }

    private static List<String> readLines(Path path) throws IOException {
        if (!Files.exists(path)) return new ArrayList<>();
        String content = Files.readString(path).trim();
        if (content.isEmpty()) return new ArrayList<>();
        return new ArrayList<>(Arrays.asList(content.split("\n")));
    }
}
