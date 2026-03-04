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
        Files.write(INDEX, new byte[0]);
        Files.write(HEAD, new byte[0]);
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
        List<String> lines = readLines(INDEX);
        if (!lines.contains(filename)) {
            lines.add(filename);
            Files.write(INDEX, String.join("\n", lines).concat("\n").getBytes());
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

        List<String> indexLines = readLines(INDEX);
        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String parent = new String(Files.readAllBytes(HEAD)).trim();
        if (parent.isEmpty()) parent = "NONE";

        long timestamp = System.currentTimeMillis() / 1000;

        // Sort filenames
        Collections.sort(indexLines);

        // Build file entries: filename blobhash
        StringBuilder filesSection = new StringBuilder();
        for (String filename : indexLines) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String hash = miniHash(content);
            filesSection.append(filename).append(" ").append(hash).append("\n");
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

    static void log() throws Exception {
        String hash = new String(Files.readAllBytes(HEAD)).trim();
        if (hash.isEmpty()) {
            System.out.println("No commits");
            return;
        }
        while (!hash.isEmpty() && !hash.equals("NONE")) {
            Path commitFile = COMMITS.resolve(hash);
            String content = new String(Files.readAllBytes(commitFile));
            String ts = "", msg = "", parent = "";
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

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
    }

    static List<String> readLines(Path path) throws Exception {
        if (!Files.exists(path)) return new ArrayList<>();
        String content = new String(Files.readAllBytes(path)).trim();
        if (content.isEmpty()) return new ArrayList<>();
        return new ArrayList<>(Arrays.asList(content.split("\n")));
    }
}
