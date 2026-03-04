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
            case "log":
                doLog();
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
