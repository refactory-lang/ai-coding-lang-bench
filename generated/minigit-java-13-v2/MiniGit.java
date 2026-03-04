import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;

public class MiniGit {

    static final Path MINIGIT = Paths.get(".minigit");
    static final Path OBJECTS = MINIGIT.resolve("objects");
    static final Path COMMITS = MINIGIT.resolve("commits");
    static final Path INDEX = MINIGIT.resolve("index");
    static final Path HEAD = MINIGIT.resolve("HEAD");

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }
        switch (args[0]) {
            case "init": init(); break;
            case "add": add(args); break;
            case "commit": commit(args); break;
            case "status": status(); break;
            case "log": log(); break;
            case "diff": diff(args); break;
            case "checkout": checkout(args); break;
            case "reset": reset(args); break;
            case "rm": rm(args); break;
            case "show": show(args); break;
            default:
                System.err.println("Unknown command: " + args[0]);
                System.exit(1);
        }
    }

    static void init() throws Exception {
        if (Files.isDirectory(MINIGIT)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS);
        Files.createDirectories(COMMITS);
        Files.writeString(INDEX, "");
        Files.writeString(HEAD, "");
    }

    static void add(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit add <file>");
            System.exit(1);
        }
        String filename = args[1];
        Path filePath = Paths.get(filename);
        if (!Files.exists(filePath)) {
            System.out.println("File not found");
            System.exit(1);
        }
        byte[] content = Files.readAllBytes(filePath);
        String hash = miniHash(content);
        Files.write(OBJECTS.resolve(hash), content);

        // Add to index if not already present
        String indexContent = Files.readString(INDEX);
        List<String> lines = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String line : indexContent.split("\n", -1)) {
                if (!line.isEmpty()) lines.add(line);
            }
        }
        if (!lines.contains(filename)) {
            lines.add(filename);
            Files.writeString(INDEX, String.join("\n", lines) + "\n");
        }
    }

    static void commit(String[] args) throws Exception {
        String message = null;
        for (int i = 1; i < args.length; i++) {
            if (args[i].equals("-m") && i + 1 < args.length) {
                message = args[i + 1];
                break;
            }
        }
        if (message == null) {
            System.err.println("Usage: minigit commit -m \"<message>\"");
            System.exit(1);
        }

        String indexContent = Files.readString(INDEX);
        List<String> staged = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String line : indexContent.split("\n", -1)) {
                if (!line.isEmpty()) staged.add(line);
            }
        }
        if (staged.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        Collections.sort(staged);

        String headContent = Files.readString(HEAD).trim();
        String parent = headContent.isEmpty() ? "NONE" : headContent;
        long timestamp = System.currentTimeMillis() / 1000;

        StringBuilder sb = new StringBuilder();
        sb.append("parent: ").append(parent).append("\n");
        sb.append("timestamp: ").append(timestamp).append("\n");
        sb.append("message: ").append(message).append("\n");
        sb.append("files:\n");
        for (String filename : staged) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String blobHash = miniHash(content);
            // Ensure blob is stored
            Files.write(OBJECTS.resolve(blobHash), content);
            sb.append(filename).append(" ").append(blobHash).append("\n");
        }

        String commitContent = sb.toString();
        String commitHash = miniHash(commitContent.getBytes());
        Files.writeString(COMMITS.resolve(commitHash), commitContent);
        Files.writeString(HEAD, commitHash);
        Files.writeString(INDEX, "");

        System.out.println("Committed " + commitHash);
    }

    static void log() throws Exception {
        String headContent = Files.readString(HEAD).trim();
        if (headContent.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = headContent;
        while (!current.equals("NONE") && !current.isEmpty()) {
            String commitContent = Files.readString(COMMITS.resolve(current));
            String commitTimestamp = "";
            String commitMessage = "";
            String commitParent = "NONE";

            for (String line : commitContent.split("\n")) {
                if (line.startsWith("parent: ")) commitParent = line.substring(8);
                else if (line.startsWith("timestamp: ")) commitTimestamp = line.substring(11);
                else if (line.startsWith("message: ")) commitMessage = line.substring(9);
            }

            System.out.println("commit " + current);
            System.out.println("Date: " + commitTimestamp);
            System.out.println("Message: " + commitMessage);
            System.out.println();

            current = commitParent;
        }
    }

    static void status() throws Exception {
        String indexContent = Files.readString(INDEX);
        List<String> staged = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String line : indexContent.split("\n", -1)) {
                if (!line.isEmpty()) staged.add(line);
            }
        }
        System.out.println("Staged files:");
        if (staged.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : staged) {
                System.out.println(f);
            }
        }
    }

    static void diff(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("Usage: minigit diff <commit1> <commit2>");
            System.exit(1);
        }
        String hash1 = args[1];
        String hash2 = args[2];
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

    static void checkout(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit checkout <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String commitContent = Files.readString(commitPath);
        Map<String, String> files = parseCommitFiles(commitContent);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blob = Files.readAllBytes(OBJECTS.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blob);
        }
        Files.writeString(HEAD, hash);
        Files.writeString(INDEX, "");
        System.out.println("Checked out " + hash);
    }

    static void reset(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit reset <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.writeString(HEAD, hash);
        Files.writeString(INDEX, "");
        System.out.println("Reset to " + hash);
    }

    static void rm(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit rm <file>");
            System.exit(1);
        }
        String filename = args[1];
        String indexContent = Files.readString(INDEX);
        List<String> lines = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String line : indexContent.split("\n", -1)) {
                if (!line.isEmpty()) lines.add(line);
            }
        }
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

    static void show(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit show <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String commitContent = Files.readString(commitPath);
        String timestamp = "";
        String message = "";
        for (String line : commitContent.split("\n")) {
            if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
            else if (line.startsWith("message: ")) message = line.substring(9);
        }
        Map<String, String> files = parseCommitFiles(commitContent);
        System.out.println("commit " + hash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : new TreeMap<>(files).entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    static Map<String, String> parseCommitFiles(String commitContent) {
        Map<String, String> files = new LinkedHashMap<>();
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

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }
}
