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

        // Read existing index entries
        List<String> entries = readIndex();
        if (!entries.contains(filename)) {
            entries.add(filename);
            Files.write(INDEX, String.join("\n", entries).concat("\n").getBytes());
        }
    }

    static void doCommit(String message) throws Exception {
        List<String> entries = readIndex();
        if (entries.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String parent = new String(Files.readAllBytes(HEAD)).trim();
        if (parent.isEmpty()) parent = "NONE";

        long timestamp = System.currentTimeMillis() / 1000;

        // Sort filenames
        Collections.sort(entries);

        // Build file lines with blob hashes
        StringBuilder filesSection = new StringBuilder();
        for (String fname : entries) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String blobHash = miniHash(content);
            filesSection.append(fname).append(" ").append(blobHash).append("\n");
        }

        String commitContent = "parent: " + parent + "\n"
                + "timestamp: " + timestamp + "\n"
                + "message: " + message + "\n"
                + "files:\n"
                + filesSection.toString();

        String commitHash = miniHash(commitContent.getBytes());
        Files.write(COMMITS.resolve(commitHash), commitContent.getBytes());
        Files.write(HEAD, commitHash.getBytes());
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
            String content = new String(Files.readAllBytes(COMMITS.resolve(hash)));
            String ts = "";
            String msg = "";
            String parent = "";
            for (String line : content.split("\n")) {
                if (line.startsWith("parent: ")) parent = line.substring(8);
                else if (line.startsWith("timestamp: ")) ts = line.substring(11);
                else if (line.startsWith("message: ")) msg = line.substring(9);
            }
            System.out.println("commit " + hash);
            System.out.println("Date: " + ts);
            System.out.println("Message: " + msg);
            System.out.println();
            hash = parent;
        }
    }

    static List<String> readIndex() throws Exception {
        if (!Files.exists(INDEX)) return new ArrayList<>();
        String content = new String(Files.readAllBytes(INDEX)).trim();
        if (content.isEmpty()) return new ArrayList<>();
        return new ArrayList<>(Arrays.asList(content.split("\n")));
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
