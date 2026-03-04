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
            case "log": log(); break;
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

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }
}
