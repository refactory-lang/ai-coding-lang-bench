import java.io.*;
import java.nio.file.*;
import java.util.*;

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
                System.err.println("Unknown command: " + args[0]);
                System.exit(1);
        }
    }

    static void doInit() throws Exception {
        if (Files.isDirectory(MINIGIT)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS);
        Files.createDirectories(COMMITS);
        Files.write(INDEX, new byte[0]);
        Files.write(HEAD, new byte[0]);
    }

    static void doAdd(String filename) throws Exception {
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
            writeLines(INDEX, lines);
        }
    }

    static void doCommit(String message) throws Exception {
        List<String> indexed = readLines(INDEX);
        if (indexed.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String parent = new String(Files.readAllBytes(HEAD)).trim();
        if (parent.isEmpty()) {
            parent = "NONE";
        }

        long timestamp = System.currentTimeMillis() / 1000;

        // Build file entries sorted lexicographically
        List<String> sortedFiles = new ArrayList<>(indexed);
        Collections.sort(sortedFiles);

        StringBuilder sb = new StringBuilder();
        sb.append("parent: ").append(parent).append("\n");
        sb.append("timestamp: ").append(timestamp).append("\n");
        sb.append("message: ").append(message).append("\n");
        sb.append("files:\n");
        for (String fname : sortedFiles) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String blobHash = miniHash(content);
            sb.append(fname).append(" ").append(blobHash).append("\n");
        }

        String commitContent = sb.toString();
        String commitHash = miniHash(commitContent.getBytes("UTF-8"));

        Files.write(COMMITS.resolve(commitHash), commitContent.getBytes("UTF-8"));
        Files.write(HEAD, commitHash.getBytes("UTF-8"));
        // Clear index
        Files.write(INDEX, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    static void doLog() throws Exception {
        String hash = new String(Files.readAllBytes(HEAD)).trim();
        if (hash.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        while (!hash.isEmpty() && !hash.equals("NONE")) {
            Path commitPath = COMMITS.resolve(hash);
            String content = new String(Files.readAllBytes(commitPath), "UTF-8");
            String parentHash = "";
            String timestamp = "";
            String message = "";
            for (String line : content.split("\n")) {
                if (line.startsWith("parent: ")) {
                    parentHash = line.substring(8);
                } else if (line.startsWith("timestamp: ")) {
                    timestamp = line.substring(11);
                } else if (line.startsWith("message: ")) {
                    message = line.substring(9);
                }
            }
            System.out.println("commit " + hash);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);
            System.out.println();
            hash = parentHash;
        }
    }

    static void doStatus() throws Exception {
        List<String> indexed = readLines(INDEX);
        System.out.println("Staged files:");
        if (indexed.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : indexed) {
                System.out.println(f);
            }
        }
    }

    static Map<String, String> parseCommitFiles(String content) {
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : content.split("\n")) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.trim().isEmpty()) {
                int sp = line.indexOf(' ');
                if (sp > 0) {
                    files.put(line.substring(0, sp), line.substring(sp + 1));
                }
            }
        }
        return files;
    }

    static void doDiff(String hash1, String hash2) throws Exception {
        Path c1 = COMMITS.resolve(hash1);
        Path c2 = COMMITS.resolve(hash2);
        if (!Files.exists(c1) || !Files.exists(c2)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files1 = parseCommitFiles(new String(Files.readAllBytes(c1), "UTF-8"));
        Map<String, String> files2 = parseCommitFiles(new String(Files.readAllBytes(c2), "UTF-8"));

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

    static void doCheckout(String hash) throws Exception {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = new String(Files.readAllBytes(commitPath), "UTF-8");
        Map<String, String> files = parseCommitFiles(content);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blob = Files.readAllBytes(OBJECTS.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blob);
        }
        Files.write(HEAD, hash.getBytes("UTF-8"));
        Files.write(INDEX, new byte[0]);
        System.out.println("Checked out " + hash);
    }

    static void doReset(String hash) throws Exception {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.write(HEAD, hash.getBytes("UTF-8"));
        Files.write(INDEX, new byte[0]);
        System.out.println("Reset to " + hash);
    }

    static void doRm(String filename) throws Exception {
        List<String> lines = readLines(INDEX);
        if (!lines.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        lines.remove(filename);
        writeLines(INDEX, lines);
    }

    static void doShow(String hash) throws Exception {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = new String(Files.readAllBytes(commitPath), "UTF-8");
        String timestamp = "";
        String message = "";
        for (String line : content.split("\n")) {
            if (line.startsWith("timestamp: ")) {
                timestamp = line.substring(11);
            } else if (line.startsWith("message: ")) {
                message = line.substring(9);
            }
        }
        System.out.println("commit " + hash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        Map<String, String> files = parseCommitFiles(content);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }

    static List<String> readLines(Path path) throws Exception {
        List<String> result = new ArrayList<>();
        if (!Files.exists(path)) return result;
        for (String line : Files.readAllLines(path)) {
            if (!line.trim().isEmpty()) {
                result.add(line.trim());
            }
        }
        return result;
    }

    static void writeLines(Path path, List<String> lines) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (String line : lines) {
            sb.append(line).append("\n");
        }
        Files.write(path, sb.toString().getBytes("UTF-8"));
    }
}
