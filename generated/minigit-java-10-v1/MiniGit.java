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

    static String miniHash(byte[] data) {
        long h = Long.parseUnsignedLong("1469598103934665603");
        for (byte b : data) {
            h ^= (b & 0xFF);
            h *= 1099511628211L;
        }
        return String.format("%016x", h);
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
        Path file = Paths.get(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }
        byte[] content = Files.readAllBytes(file);
        String hash = miniHash(content);
        Files.write(OBJECTS.resolve(hash), content);

        // Read existing index entries
        List<String> entries = new ArrayList<>();
        String indexContent = new String(Files.readAllBytes(INDEX)).trim();
        if (!indexContent.isEmpty()) {
            entries.addAll(Arrays.asList(indexContent.split("\n")));
        }
        if (!entries.contains(filename)) {
            entries.add(filename);
        }
        StringBuilder sb = new StringBuilder();
        for (String e : entries) {
            sb.append(e).append("\n");
        }
        Files.write(INDEX, sb.toString().getBytes());
    }

    static void commit(String[] args) throws Exception {
        // Parse -m message
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

        String indexContent = new String(Files.readAllBytes(INDEX)).trim();
        if (indexContent.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        List<String> filenames = Arrays.asList(indexContent.split("\n"));
        Collections.sort(filenames);

        String headContent = new String(Files.readAllBytes(HEAD)).trim();
        String parent = headContent.isEmpty() ? "NONE" : headContent;

        long timestamp = System.currentTimeMillis() / 1000;

        StringBuilder commitContent = new StringBuilder();
        commitContent.append("parent: ").append(parent).append("\n");
        commitContent.append("timestamp: ").append(timestamp).append("\n");
        commitContent.append("message: ").append(message).append("\n");
        commitContent.append("files:\n");
        for (String fname : filenames) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String blobHash = miniHash(content);
            commitContent.append(fname).append(" ").append(blobHash).append("\n");
        }

        String commitStr = commitContent.toString();
        String commitHash = miniHash(commitStr.getBytes());

        Files.write(COMMITS.resolve(commitHash), commitStr.getBytes());
        Files.write(HEAD, commitHash.getBytes());
        Files.write(INDEX, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    static void log() throws Exception {
        String headContent = new String(Files.readAllBytes(HEAD)).trim();
        if (headContent.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = headContent;
        while (!current.equals("NONE") && !current.isEmpty()) {
            Path commitFile = COMMITS.resolve(current);
            String content = new String(Files.readAllBytes(commitFile));
            String[] lines = content.split("\n");

            String parent = "";
            String timestamp = "";
            String message = "";
            for (String line : lines) {
                if (line.startsWith("parent: ")) parent = line.substring(8);
                else if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
                else if (line.startsWith("message: ")) message = line.substring(9);
            }

            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);
            System.out.println();

            current = parent;
        }
    }
}
