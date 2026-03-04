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

    private static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }

    private static void doInit() throws Exception {
        if (Files.exists(MINIGIT_DIR)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS_DIR);
        Files.createDirectories(COMMITS_DIR);
        Files.writeString(INDEX_FILE, "");
        Files.writeString(HEAD_FILE, "");
    }

    private static void doAdd(String filename) throws Exception {
        Path file = Paths.get(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }

        byte[] content = Files.readAllBytes(file);
        String hash = miniHash(content);

        // Store blob
        Path blobPath = OBJECTS_DIR.resolve(hash);
        Files.write(blobPath, content);

        // Update index
        List<String> indexLines = new ArrayList<>();
        if (Files.exists(INDEX_FILE)) {
            String existing = Files.readString(INDEX_FILE).trim();
            if (!existing.isEmpty()) {
                indexLines.addAll(Arrays.asList(existing.split("\n")));
            }
        }
        if (!indexLines.contains(filename)) {
            indexLines.add(filename);
        }
        Files.writeString(INDEX_FILE, String.join("\n", indexLines) + "\n");
    }

    private static void doCommit(String message) throws Exception {
        // Read index
        List<String> indexLines = new ArrayList<>();
        if (Files.exists(INDEX_FILE)) {
            String existing = Files.readString(INDEX_FILE).trim();
            if (!existing.isEmpty()) {
                indexLines.addAll(Arrays.asList(existing.split("\n")));
            }
        }

        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        // Read HEAD
        String parent = Files.readString(HEAD_FILE).trim();
        if (parent.isEmpty()) {
            parent = "NONE";
        }

        // Get timestamp
        long timestamp = System.currentTimeMillis() / 1000;

        // Sort filenames
        Collections.sort(indexLines);

        // Build file entries with hashes
        StringBuilder filesSection = new StringBuilder();
        for (String filename : indexLines) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String hash = miniHash(content);
            // Also store the blob (in case file was modified after add)
            Files.write(OBJECTS_DIR.resolve(hash), content);
            filesSection.append(filename).append(" ").append(hash).append("\n");
        }

        // Build commit content
        String commitContent = "parent: " + parent + "\n" +
                "timestamp: " + timestamp + "\n" +
                "message: " + message + "\n" +
                "files:\n" +
                filesSection.toString();

        // Hash commit
        String commitHash = miniHash(commitContent.getBytes());

        // Write commit file
        Files.writeString(COMMITS_DIR.resolve(commitHash), commitContent);

        // Update HEAD
        Files.writeString(HEAD_FILE, commitHash);

        // Clear index
        Files.writeString(INDEX_FILE, "");

        System.out.println("Committed " + commitHash);
    }

    private static void doLog() throws Exception {
        if (!Files.exists(HEAD_FILE)) {
            System.out.println("No commits");
            return;
        }

        String current = Files.readString(HEAD_FILE).trim();
        if (current.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        boolean first = true;
        while (!current.isEmpty() && !current.equals("NONE")) {
            if (!first) {
                System.out.println();
            }
            first = false;

            Path commitFile = COMMITS_DIR.resolve(current);
            if (!Files.exists(commitFile)) break;

            String content = Files.readString(commitFile);
            String[] lines = content.split("\n");

            String parentVal = "";
            String timestampVal = "";
            String messageVal = "";

            for (String line : lines) {
                if (line.startsWith("parent: ")) {
                    parentVal = line.substring("parent: ".length());
                } else if (line.startsWith("timestamp: ")) {
                    timestampVal = line.substring("timestamp: ".length());
                } else if (line.startsWith("message: ")) {
                    messageVal = line.substring("message: ".length());
                }
            }

            System.out.println("commit " + current);
            System.out.println("Date: " + timestampVal);
            System.out.println("Message: " + messageVal);

            current = parentVal.equals("NONE") ? "" : parentVal;
        }
    }
}
