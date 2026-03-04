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
            case "log":
                log();
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
}
