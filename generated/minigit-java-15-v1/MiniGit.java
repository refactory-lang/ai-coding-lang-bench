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
        if (args.length < 1) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }
        switch (args[0]) {
            case "init":
                doInit();
                break;
            case "add":
                if (args.length < 2) { System.err.println("Usage: minigit add <file>"); System.exit(1); }
                doAdd(args[1]);
                break;
            case "commit":
                if (args.length < 3 || !args[1].equals("-m")) { System.err.println("Usage: minigit commit -m <msg>"); System.exit(1); }
                doCommit(args[2]);
                break;
            case "log":
                doLog();
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
        Files.writeString(INDEX, "");
        Files.writeString(HEAD, "");
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
        String indexContent = Files.readString(INDEX);
        List<String> lines = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String l : indexContent.split("\n", -1)) {
                if (!l.isEmpty()) lines.add(l);
            }
        }
        if (!lines.contains(filename)) {
            lines.add(filename);
            Files.writeString(INDEX, String.join("\n", lines) + "\n");
        }
    }

    static void doCommit(String message) throws Exception {
        String indexContent = Files.readString(INDEX);
        List<String> staged = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String l : indexContent.split("\n", -1)) {
                if (!l.isEmpty()) staged.add(l);
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
        for (String fname : staged) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String hash = miniHash(content);
            sb.append(fname).append(" ").append(hash).append("\n");
        }

        String commitContent = sb.toString();
        String commitHash = miniHash(commitContent.getBytes());

        Files.writeString(COMMITS.resolve(commitHash), commitContent);
        Files.writeString(HEAD, commitHash);
        Files.writeString(INDEX, "");

        System.out.println("Committed " + commitHash);
    }

    static void doLog() throws Exception {
        String hash = Files.readString(HEAD).trim();
        if (hash.isEmpty()) {
            System.out.println("No commits");
            return;
        }
        while (!hash.isEmpty() && !hash.equals("NONE")) {
            String content = Files.readString(COMMITS.resolve(hash));
            String parentLine = null, timestampLine = null, messageLine = null;
            for (String line : content.split("\n")) {
                if (line.startsWith("parent: ")) parentLine = line.substring(8);
                else if (line.startsWith("timestamp: ")) timestampLine = line.substring(11);
                else if (line.startsWith("message: ")) messageLine = line.substring(9);
            }
            System.out.println("commit " + hash);
            System.out.println("Date: " + timestampLine);
            System.out.println("Message: " + messageLine);
            System.out.println();
            hash = parentLine;
        }
    }

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        // Format as unsigned 16-char hex
        String hex = String.format("%016x", h);
        return hex;
    }
}
