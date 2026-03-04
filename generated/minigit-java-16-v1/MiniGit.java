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

        // Store blob
        Path blobPath = OBJECTS_DIR.resolve(hash);
        Files.write(blobPath, content);

        // Update index
        List<String> indexLines = readIndex();
        if (!indexLines.contains(filename)) {
            indexLines.add(filename);
            Files.write(INDEX_FILE, String.join("\n", indexLines).getBytes());
        }
    }

    private static void doCommit(String message) throws Exception {
        List<String> indexLines = readIndex();
        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String head = new String(Files.readAllBytes(HEAD_FILE)).trim();
        String parent = head.isEmpty() ? "NONE" : head;
        long timestamp = System.currentTimeMillis() / 1000;

        // Sort filenames
        Collections.sort(indexLines);

        // Build file entries
        StringBuilder filesSection = new StringBuilder();
        for (String fname : indexLines) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String hash = miniHash(content);
            filesSection.append(fname).append(" ").append(hash).append("\n");
        }

        String commitContent = "parent: " + parent + "\n" +
                "timestamp: " + timestamp + "\n" +
                "message: " + message + "\n" +
                "files:\n" +
                filesSection.toString();

        String commitHash = miniHash(commitContent.getBytes());

        // Write commit
        Files.write(COMMITS_DIR.resolve(commitHash), commitContent.getBytes());

        // Update HEAD
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

            String parentVal = "";
            String timestampVal = "";
            String messageVal = "";

            for (String line : lines) {
                if (line.startsWith("parent: ")) {
                    parentVal = line.substring(8);
                } else if (line.startsWith("timestamp: ")) {
                    timestampVal = line.substring(11);
                } else if (line.startsWith("message: ")) {
                    messageVal = line.substring(9);
                }
            }

            System.out.println("commit " + current);
            System.out.println("Date: " + timestampVal);
            System.out.println("Message: " + messageVal);
            System.out.println();

            current = parentVal;
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
