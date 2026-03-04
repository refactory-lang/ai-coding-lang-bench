import java.io.*;
import java.nio.file.*;
import java.util.*;

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
        if (Files.isDirectory(MINIGIT_DIR)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS_DIR);
        Files.createDirectories(COMMITS_DIR);
        Files.write(INDEX_FILE, new byte[0]);
        Files.write(HEAD_FILE, new byte[0]);
    }

    private static void doAdd(String filename) throws Exception {
        Path file = Paths.get(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }
        byte[] content = Files.readAllBytes(file);
        String hash = miniHash(content);
        Files.write(OBJECTS_DIR.resolve(hash), content);

        // Read current index
        List<String> indexed = readIndex();
        if (!indexed.contains(filename)) {
            indexed.add(filename);
            Files.write(INDEX_FILE, String.join("\n", indexed).concat("\n").getBytes());
        }
    }

    private static void doCommit(String message) throws Exception {
        List<String> indexed = readIndex();
        if (indexed.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String parent = new String(Files.readAllBytes(HEAD_FILE)).trim();
        if (parent.isEmpty()) {
            parent = "NONE";
        }

        long timestamp = System.currentTimeMillis() / 1000;

        // Build file list: for each indexed file, compute its current blob hash
        // Sort filenames lexicographically
        List<String> sortedFiles = new ArrayList<>(indexed);
        Collections.sort(sortedFiles);

        StringBuilder commitContent = new StringBuilder();
        commitContent.append("parent: ").append(parent).append("\n");
        commitContent.append("timestamp: ").append(timestamp).append("\n");
        commitContent.append("message: ").append(message).append("\n");
        commitContent.append("files:\n");
        for (String fname : sortedFiles) {
            // Read the blob hash for this file from objects
            byte[] fileContent = Files.readAllBytes(Paths.get(fname));
            String blobHash = miniHash(fileContent);
            commitContent.append(fname).append(" ").append(blobHash).append("\n");
        }

        String commitStr = commitContent.toString();
        String commitHash = miniHash(commitStr.getBytes());

        Files.write(COMMITS_DIR.resolve(commitHash), commitStr.getBytes());
        Files.write(HEAD_FILE, commitHash.getBytes());
        // Clear index
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    private static void doLog() throws Exception {
        String head = new String(Files.readAllBytes(HEAD_FILE)).trim();
        if (head.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = head;
        while (!current.equals("NONE") && !current.isEmpty()) {
            Path commitPath = COMMITS_DIR.resolve(current);
            String content = new String(Files.readAllBytes(commitPath));
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

    private static List<String> readIndex() throws Exception {
        if (!Files.exists(INDEX_FILE)) {
            return new ArrayList<>();
        }
        String content = new String(Files.readAllBytes(INDEX_FILE)).trim();
        if (content.isEmpty()) {
            return new ArrayList<>();
        }
        return new ArrayList<>(Arrays.asList(content.split("\n")));
    }
}
