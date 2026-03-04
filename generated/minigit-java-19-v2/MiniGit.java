import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;

public class MiniGit {

    private static final Path MINIGIT_DIR = Paths.get(".minigit");
    private static final Path OBJECTS_DIR = MINIGIT_DIR.resolve("objects");
    private static final Path COMMITS_DIR = MINIGIT_DIR.resolve("commits");
    private static final Path INDEX_FILE = MINIGIT_DIR.resolve("index");
    private static final Path HEAD_FILE = MINIGIT_DIR.resolve("HEAD");

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }
        switch (args[0]) {
            case "init":
                init();
                break;
            case "add":
                if (args.length < 2) {
                    System.err.println("Usage: minigit add <file>");
                    System.exit(1);
                }
                add(args[1]);
                break;
            case "commit":
                if (args.length < 3 || !args[1].equals("-m")) {
                    System.err.println("Usage: minigit commit -m \"<message>\"");
                    System.exit(1);
                }
                commit(args[2]);
                break;
            case "status":
                status();
                break;
            case "log":
                log();
                break;
            case "diff":
                if (args.length < 3) {
                    System.err.println("Usage: minigit diff <commit1> <commit2>");
                    System.exit(1);
                }
                diff(args[1], args[2]);
                break;
            case "checkout":
                if (args.length < 2) {
                    System.err.println("Usage: minigit checkout <commit_hash>");
                    System.exit(1);
                }
                checkout(args[1]);
                break;
            case "reset":
                if (args.length < 2) {
                    System.err.println("Usage: minigit reset <commit_hash>");
                    System.exit(1);
                }
                reset(args[1]);
                break;
            case "rm":
                if (args.length < 2) {
                    System.err.println("Usage: minigit rm <file>");
                    System.exit(1);
                }
                rm(args[1]);
                break;
            case "show":
                if (args.length < 2) {
                    System.err.println("Usage: minigit show <commit_hash>");
                    System.exit(1);
                }
                show(args[1]);
                break;
            default:
                System.err.println("Unknown command: " + args[0]);
                System.exit(1);
        }
    }

    private static String miniHash(byte[] data) {
        long h = Long.parseUnsignedLong("1469598103934665603");
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }

    private static void init() throws Exception {
        if (Files.isDirectory(MINIGIT_DIR)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS_DIR);
        Files.createDirectories(COMMITS_DIR);
        Files.writeString(INDEX_FILE, "");
        Files.writeString(HEAD_FILE, "");
    }

    private static void add(String filename) throws Exception {
        Path file = Paths.get(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }
        byte[] content = Files.readAllBytes(file);
        String hash = miniHash(content);
        Files.write(OBJECTS_DIR.resolve(hash), content);

        List<String> indexed = readIndex();
        if (!indexed.contains(filename)) {
            indexed.add(filename);
            Files.writeString(INDEX_FILE, String.join("\n", indexed) + "\n");
        }
    }

    private static List<String> readIndex() throws Exception {
        if (!Files.exists(INDEX_FILE)) return new ArrayList<>();
        String content = Files.readString(INDEX_FILE).trim();
        if (content.isEmpty()) return new ArrayList<>();
        return new ArrayList<>(Arrays.asList(content.split("\n")));
    }

    private static void commit(String message) throws Exception {
        List<String> indexed = readIndex();
        if (indexed.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String head = Files.readString(HEAD_FILE).trim();
        String parent = head.isEmpty() ? "NONE" : head;
        long timestamp = System.currentTimeMillis() / 1000;

        Collections.sort(indexed);

        StringBuilder sb = new StringBuilder();
        sb.append("parent: ").append(parent).append("\n");
        sb.append("timestamp: ").append(timestamp).append("\n");
        sb.append("message: ").append(message).append("\n");
        sb.append("files:\n");

        for (String fname : indexed) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String blobHash = miniHash(content);
            sb.append(fname).append(" ").append(blobHash).append("\n");
        }

        String commitContent = sb.toString();
        String commitHash = miniHash(commitContent.getBytes());

        Files.writeString(COMMITS_DIR.resolve(commitHash), commitContent);
        Files.writeString(HEAD_FILE, commitHash);
        Files.writeString(INDEX_FILE, "");

        System.out.println("Committed " + commitHash);
    }

    private static void log() throws Exception {
        if (!Files.exists(HEAD_FILE)) {
            System.out.println("No commits");
            return;
        }
        String hash = Files.readString(HEAD_FILE).trim();
        if (hash.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        while (!hash.isEmpty() && !hash.equals("NONE")) {
            Path commitFile = COMMITS_DIR.resolve(hash);
            if (!Files.exists(commitFile)) break;
            String content = Files.readString(commitFile);
            String[] lines = content.split("\n");

            String parentHash = "";
            String ts = "";
            String msg = "";
            for (String line : lines) {
                if (line.startsWith("parent: ")) parentHash = line.substring(8);
                else if (line.startsWith("timestamp: ")) ts = line.substring(11);
                else if (line.startsWith("message: ")) msg = line.substring(9);
            }

            System.out.println("commit " + hash);
            System.out.println("Date: " + ts);
            System.out.println("Message: " + msg);
            System.out.println();

            hash = parentHash.equals("NONE") ? "" : parentHash;
        }
    }

    private static void status() throws Exception {
        List<String> indexed = readIndex();
        System.out.println("Staged files:");
        if (indexed.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : indexed) {
                System.out.println(f);
            }
        }
    }

    private static Map<String, String> parseCommitFiles(String content) {
        Map<String, String> files = new TreeMap<>();
        String[] lines = content.split("\n");
        boolean inFiles = false;
        for (String line : lines) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.isEmpty()) {
                int sp = line.lastIndexOf(' ');
                if (sp > 0) {
                    files.put(line.substring(0, sp), line.substring(sp + 1));
                }
            }
        }
        return files;
    }

    private static void diff(String hash1, String hash2) throws Exception {
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

    private static void checkout(String hash) throws Exception {
        Path commitFile = COMMITS_DIR.resolve(hash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files = parseCommitFiles(Files.readString(commitFile));
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blob = Files.readAllBytes(OBJECTS_DIR.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blob);
        }
        Files.writeString(HEAD_FILE, hash);
        Files.writeString(INDEX_FILE, "");
        System.out.println("Checked out " + hash);
    }

    private static void reset(String hash) throws Exception {
        Path commitFile = COMMITS_DIR.resolve(hash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.writeString(HEAD_FILE, hash);
        Files.writeString(INDEX_FILE, "");
        System.out.println("Reset to " + hash);
    }

    private static void rm(String filename) throws Exception {
        List<String> indexed = readIndex();
        if (!indexed.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        indexed.remove(filename);
        if (indexed.isEmpty()) {
            Files.writeString(INDEX_FILE, "");
        } else {
            Files.writeString(INDEX_FILE, String.join("\n", indexed) + "\n");
        }
    }

    private static void show(String hash) throws Exception {
        Path commitFile = COMMITS_DIR.resolve(hash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = Files.readString(commitFile);
        String[] lines = content.split("\n");
        String ts = "";
        String msg = "";
        for (String line : lines) {
            if (line.startsWith("timestamp: ")) ts = line.substring(11);
            else if (line.startsWith("message: ")) msg = line.substring(9);
        }
        Map<String, String> files = parseCommitFiles(content);
        System.out.println("commit " + hash);
        System.out.println("Date: " + ts);
        System.out.println("Message: " + msg);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : files.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }
}
