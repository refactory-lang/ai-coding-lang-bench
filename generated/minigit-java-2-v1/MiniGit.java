import java.io.*;
import java.nio.file.*;
import java.util.*;

public class MiniGit {

    static final String MINIGIT_DIR = ".minigit";
    static final String OBJECTS_DIR = MINIGIT_DIR + "/objects";
    static final String COMMITS_DIR = MINIGIT_DIR + "/commits";
    static final String INDEX_FILE = MINIGIT_DIR + "/index";
    static final String HEAD_FILE = MINIGIT_DIR + "/HEAD";

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
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

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h ^= (b & 0xFF);
            h = h * 1099511628211L;
        }
        return String.format("%016x", h);
    }

    static void init() throws Exception {
        Path minigitDir = Paths.get(MINIGIT_DIR);
        if (Files.exists(minigitDir)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(Paths.get(OBJECTS_DIR));
        Files.createDirectories(Paths.get(COMMITS_DIR));
        Files.write(Paths.get(INDEX_FILE), new byte[0]);
        Files.write(Paths.get(HEAD_FILE), new byte[0]);
    }

    static void add(String filename) throws Exception {
        Path filePath = Paths.get(filename);
        if (!Files.exists(filePath)) {
            System.out.println("File not found");
            System.exit(1);
        }

        byte[] content = Files.readAllBytes(filePath);
        String hash = miniHash(content);

        Files.write(Paths.get(OBJECTS_DIR, hash), content);

        Path indexPath = Paths.get(INDEX_FILE);
        List<String> lines = new ArrayList<>();
        if (Files.exists(indexPath) && Files.size(indexPath) > 0) {
            for (String line : Files.readAllLines(indexPath)) {
                if (!line.trim().isEmpty()) {
                    lines.add(line.trim());
                }
            }
        }

        if (!lines.contains(filename)) {
            lines.add(filename);
            StringBuilder sb = new StringBuilder();
            for (String l : lines) {
                sb.append(l).append("\n");
            }
            Files.write(indexPath, sb.toString().getBytes());
        }
    }

    static void commit(String message) throws Exception {
        Path indexPath = Paths.get(INDEX_FILE);
        List<String> indexLines = new ArrayList<>();
        if (Files.exists(indexPath) && Files.size(indexPath) > 0) {
            for (String line : Files.readAllLines(indexPath)) {
                if (!line.trim().isEmpty()) {
                    indexLines.add(line.trim());
                }
            }
        }

        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        Path headPath = Paths.get(HEAD_FILE);
        String parent = "";
        if (Files.exists(headPath)) {
            parent = new String(Files.readAllBytes(headPath)).trim();
        }
        if (parent.isEmpty()) {
            parent = "NONE";
        }

        long timestamp = System.currentTimeMillis() / 1000;

        Collections.sort(indexLines);

        StringBuilder commitContent = new StringBuilder();
        commitContent.append("parent: ").append(parent).append("\n");
        commitContent.append("timestamp: ").append(timestamp).append("\n");
        commitContent.append("message: ").append(message).append("\n");
        commitContent.append("files:\n");
        for (String filename : indexLines) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String hash = miniHash(content);
            commitContent.append(filename).append(" ").append(hash).append("\n");
        }

        String commitStr = commitContent.toString();
        String commitHash = miniHash(commitStr.getBytes());

        Files.write(Paths.get(COMMITS_DIR, commitHash), commitStr.getBytes());
        Files.write(headPath, commitHash.getBytes());
        Files.write(indexPath, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    static void log() throws Exception {
        Path headPath = Paths.get(HEAD_FILE);
        String current = "";
        if (Files.exists(headPath)) {
            current = new String(Files.readAllBytes(headPath)).trim();
        }

        if (current.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        boolean first = true;
        while (!current.isEmpty() && !current.equals("NONE")) {
            Path commitPath = Paths.get(COMMITS_DIR, current);
            if (!Files.exists(commitPath)) break;

            if (!first) {
                System.out.println();
            }
            first = false;

            String timestamp = "";
            String msg = "";
            String parentHash = "";

            for (String line : Files.readAllLines(commitPath)) {
                if (line.startsWith("parent: ")) {
                    parentHash = line.substring(8);
                } else if (line.startsWith("timestamp: ")) {
                    timestamp = line.substring(11);
                } else if (line.startsWith("message: ")) {
                    msg = line.substring(9);
                }
            }

            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + msg);

            current = parentHash;
        }
    }
}
