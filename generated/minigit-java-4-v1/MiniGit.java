import java.io.*;
import java.nio.file.*;
import java.util.*;

public class MiniGit {

    private static final String MINIGIT_DIR = ".minigit";
    private static final String OBJECTS_DIR = MINIGIT_DIR + "/objects";
    private static final String COMMITS_DIR = MINIGIT_DIR + "/commits";
    private static final String INDEX_FILE = MINIGIT_DIR + "/index";
    private static final String HEAD_FILE = MINIGIT_DIR + "/HEAD";

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

    private static void doInit() throws IOException {
        Path minigitPath = Paths.get(MINIGIT_DIR);
        if (Files.exists(minigitPath)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(Paths.get(OBJECTS_DIR));
        Files.createDirectories(Paths.get(COMMITS_DIR));
        Files.write(Paths.get(INDEX_FILE), new byte[0]);
        Files.write(Paths.get(HEAD_FILE), new byte[0]);
    }

    private static void doAdd(String filename) throws IOException {
        Path filePath = Paths.get(filename);
        if (!Files.exists(filePath)) {
            System.out.println("File not found");
            System.exit(1);
        }

        byte[] content = Files.readAllBytes(filePath);
        String hash = miniHash(content);

        // Store blob
        Files.write(Paths.get(OBJECTS_DIR + "/" + hash), content);

        // Update index if not already present
        Path indexPath = Paths.get(INDEX_FILE);
        String indexContent = new String(Files.readAllBytes(indexPath), "UTF-8");
        List<String> lines = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String line : indexContent.split("\n", -1)) {
                if (!line.isEmpty()) {
                    lines.add(line);
                }
            }
        }
        if (!lines.contains(filename)) {
            lines.add(filename);
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < lines.size(); i++) {
                if (i > 0) sb.append("\n");
                sb.append(lines.get(i));
            }
            sb.append("\n");
            Files.write(indexPath, sb.toString().getBytes("UTF-8"));
        }
    }

    private static void doCommit(String message) throws IOException {
        // Read index
        Path indexPath = Paths.get(INDEX_FILE);
        String indexContent = new String(Files.readAllBytes(indexPath), "UTF-8");
        List<String> stagedFiles = new ArrayList<>();
        if (!indexContent.isEmpty()) {
            for (String line : indexContent.split("\n", -1)) {
                if (!line.isEmpty()) {
                    stagedFiles.add(line);
                }
            }
        }

        if (stagedFiles.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        // Read HEAD for parent
        String parent = new String(Files.readAllBytes(Paths.get(HEAD_FILE)), "UTF-8").trim();
        if (parent.isEmpty()) {
            parent = "NONE";
        }

        // Get timestamp
        long timestamp = System.currentTimeMillis() / 1000;

        // Sort filenames
        Collections.sort(stagedFiles);

        // Build file entries: filename + blob hash
        StringBuilder filesSection = new StringBuilder();
        for (String filename : stagedFiles) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String blobHash = miniHash(content);
            filesSection.append(filename).append(" ").append(blobHash).append("\n");
        }

        // Build commit content
        StringBuilder commitContent = new StringBuilder();
        commitContent.append("parent: ").append(parent).append("\n");
        commitContent.append("timestamp: ").append(timestamp).append("\n");
        commitContent.append("message: ").append(message).append("\n");
        commitContent.append("files:\n");
        commitContent.append(filesSection);

        String commitStr = commitContent.toString();
        String commitHash = miniHash(commitStr.getBytes("UTF-8"));

        // Write commit file
        Files.write(Paths.get(COMMITS_DIR + "/" + commitHash), commitStr.getBytes("UTF-8"));

        // Update HEAD
        Files.write(Paths.get(HEAD_FILE), commitHash.getBytes("UTF-8"));

        // Clear index
        Files.write(indexPath, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    private static void doLog() throws IOException {
        Path headPath = Paths.get(HEAD_FILE);
        if (!Files.exists(headPath)) {
            System.out.println("No commits");
            return;
        }

        String current = new String(Files.readAllBytes(headPath), "UTF-8").trim();
        if (current.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        boolean first = true;
        while (!current.isEmpty() && !current.equals("NONE")) {
            Path commitPath = Paths.get(COMMITS_DIR + "/" + current);
            if (!Files.exists(commitPath)) {
                break;
            }

            String commitContent = new String(Files.readAllBytes(commitPath), "UTF-8");

            String parentHash = "";
            String timestamp = "";
            String message = "";

            for (String line : commitContent.split("\n")) {
                if (line.startsWith("parent: ")) {
                    parentHash = line.substring("parent: ".length());
                } else if (line.startsWith("timestamp: ")) {
                    timestamp = line.substring("timestamp: ".length());
                } else if (line.startsWith("message: ")) {
                    message = line.substring("message: ".length());
                }
            }

            if (!first) {
                System.out.println();
            }
            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);

            first = false;
            current = parentHash;
        }
    }

    private static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h = h ^ (b & 0xFF);
            h = h * 1099511628211L;
        }
        return String.format("%016x", h);
    }
}
