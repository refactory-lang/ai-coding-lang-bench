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
            case "status":
                doStatus();
                break;
            case "log":
                doLog();
                break;
            case "diff":
                if (args.length < 3) {
                    System.err.println("Usage: minigit diff <commit1> <commit2>");
                    System.exit(1);
                }
                doDiff(args[1], args[2]);
                break;
            case "checkout":
                if (args.length < 2) {
                    System.err.println("Usage: minigit checkout <commit_hash>");
                    System.exit(1);
                }
                doCheckout(args[1]);
                break;
            case "reset":
                if (args.length < 2) {
                    System.err.println("Usage: minigit reset <commit_hash>");
                    System.exit(1);
                }
                doReset(args[1]);
                break;
            case "rm":
                if (args.length < 2) {
                    System.err.println("Usage: minigit rm <file>");
                    System.exit(1);
                }
                doRm(args[1]);
                break;
            case "show":
                if (args.length < 2) {
                    System.err.println("Usage: minigit show <commit_hash>");
                    System.exit(1);
                }
                doShow(args[1]);
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

    private static void doStatus() throws IOException {
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
        System.out.println("Staged files:");
        if (lines.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : lines) {
                System.out.println(f);
            }
        }
    }

    private static Map<String, String> parseCommitFiles(String commitContent) {
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : commitContent.split("\n", -1)) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.isEmpty()) {
                int sp = line.indexOf(' ');
                if (sp > 0) {
                    files.put(line.substring(0, sp), line.substring(sp + 1));
                }
            }
        }
        return files;
    }

    private static void doDiff(String hash1, String hash2) throws IOException {
        Path c1 = Paths.get(COMMITS_DIR + "/" + hash1);
        Path c2 = Paths.get(COMMITS_DIR + "/" + hash2);
        if (!Files.exists(c1) || !Files.exists(c2)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files1 = parseCommitFiles(new String(Files.readAllBytes(c1), "UTF-8"));
        Map<String, String> files2 = parseCommitFiles(new String(Files.readAllBytes(c2), "UTF-8"));

        Set<String> allFiles = new TreeSet<>();
        allFiles.addAll(files1.keySet());
        allFiles.addAll(files2.keySet());

        for (String f : allFiles) {
            String h1 = files1.get(f);
            String h2 = files2.get(f);
            if (h1 == null) {
                System.out.println("Added: " + f);
            } else if (h2 == null) {
                System.out.println("Removed: " + f);
            } else if (!h1.equals(h2)) {
                System.out.println("Modified: " + f);
            }
        }
    }

    private static void doCheckout(String commitHash) throws IOException {
        Path commitPath = Paths.get(COMMITS_DIR + "/" + commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String commitContent = new String(Files.readAllBytes(commitPath), "UTF-8");
        Map<String, String> files = parseCommitFiles(commitContent);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blob = Files.readAllBytes(Paths.get(OBJECTS_DIR + "/" + entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blob);
        }
        Files.write(Paths.get(HEAD_FILE), commitHash.getBytes("UTF-8"));
        Files.write(Paths.get(INDEX_FILE), new byte[0]);
        System.out.println("Checked out " + commitHash);
    }

    private static void doReset(String commitHash) throws IOException {
        Path commitPath = Paths.get(COMMITS_DIR + "/" + commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.write(Paths.get(HEAD_FILE), commitHash.getBytes("UTF-8"));
        Files.write(Paths.get(INDEX_FILE), new byte[0]);
        System.out.println("Reset to " + commitHash);
    }

    private static void doRm(String filename) throws IOException {
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
            System.out.println("File not in index");
            System.exit(1);
        }
        lines.remove(filename);
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < lines.size(); i++) {
            if (i > 0) sb.append("\n");
            sb.append(lines.get(i));
        }
        if (!lines.isEmpty()) sb.append("\n");
        Files.write(indexPath, sb.toString().getBytes("UTF-8"));
    }

    private static void doShow(String commitHash) throws IOException {
        Path commitPath = Paths.get(COMMITS_DIR + "/" + commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String commitContent = new String(Files.readAllBytes(commitPath), "UTF-8");
        String timestamp = "";
        String message = "";
        for (String line : commitContent.split("\n")) {
            if (line.startsWith("timestamp: ")) {
                timestamp = line.substring("timestamp: ".length());
            } else if (line.startsWith("message: ")) {
                message = line.substring("message: ".length());
            }
        }
        Map<String, String> files = parseCommitFiles(commitContent);
        System.out.println("commit " + commitHash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : files.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
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
