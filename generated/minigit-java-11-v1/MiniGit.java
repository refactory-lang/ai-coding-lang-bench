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
        switch (args[0]) {
            case "init": doInit(); break;
            case "add": doAdd(args); break;
            case "commit": doCommit(args); break;
            case "log": doLog(); break;
            default:
                System.err.println("Unknown command: " + args[0]);
                System.exit(1);
        }
    }

    private static String miniHash(byte[] data) {
        long h = Long.parseUnsignedLong("1469598103934665603");
        for (byte b : data) {
            h ^= (b & 0xFF);
            h = Long.remainderUnsigned(h * 1099511628211L, 1L << 63) | (h * 1099511628211L < 0 ? (1L << 63) : 0);
        }
        // Simpler: just let it overflow naturally, Java long is 64-bit two's complement
        // We need mod 2^64 which is natural overflow behavior
        // Let me redo this properly
        h = Long.parseUnsignedLong("1469598103934665603");
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
            // Java long multiplication naturally wraps mod 2^64
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

    private static void doAdd(String[] args) throws Exception {
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
        Files.write(OBJECTS_DIR.resolve(hash), content);

        // Read existing index entries
        List<String> entries = new ArrayList<>();
        String indexContent = new String(Files.readAllBytes(INDEX_FILE)).trim();
        if (!indexContent.isEmpty()) {
            entries.addAll(Arrays.asList(indexContent.split("\n")));
        }
        if (!entries.contains(filename)) {
            entries.add(filename);
            Files.write(INDEX_FILE, (String.join("\n", entries) + "\n").getBytes());
        }
    }

    private static void doCommit(String[] args) throws Exception {
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

        String indexContent = new String(Files.readAllBytes(INDEX_FILE)).trim();
        if (indexContent.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        List<String> filenames = Arrays.stream(indexContent.split("\n"))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .sorted()
                .collect(Collectors.toList());

        String headContent = new String(Files.readAllBytes(HEAD_FILE)).trim();
        String parent = headContent.isEmpty() ? "NONE" : headContent;

        long timestamp = System.currentTimeMillis() / 1000;

        StringBuilder commitContent = new StringBuilder();
        commitContent.append("parent: ").append(parent).append("\n");
        commitContent.append("timestamp: ").append(timestamp).append("\n");
        commitContent.append("message: ").append(message).append("\n");
        commitContent.append("files:\n");

        for (String filename : filenames) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String blobHash = miniHash(content);
            commitContent.append(filename).append(" ").append(blobHash).append("\n");
        }

        String commitStr = commitContent.toString();
        String commitHash = miniHash(commitStr.getBytes());

        Files.write(COMMITS_DIR.resolve(commitHash), commitStr.getBytes());
        Files.write(HEAD_FILE, commitHash.getBytes());
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
            String commitContent = new String(Files.readAllBytes(COMMITS_DIR.resolve(current)));
            String[] lines = commitContent.split("\n");
            String parentHash = "NONE";
            String timestamp = "";
            String message = "";
            for (String line : lines) {
                if (line.startsWith("parent: ")) parentHash = line.substring(8);
                else if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
                else if (line.startsWith("message: ")) message = line.substring(9);
            }
            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);
            System.out.println();
            current = parentHash;
        }
    }
}
