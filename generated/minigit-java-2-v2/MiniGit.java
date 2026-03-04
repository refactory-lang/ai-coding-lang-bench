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
            case "status":
                status();
                break;
            case "log":
                log();
                break;
            case "diff":
                if (args.length < 3) {
                    System.err.println("Usage: minigit diff <commit1> <commit2>");
                    System.exit(1);
                }
                diff(args[1], args[2]);
                break;
            case "checkout":
                if (args.length < 2) {
                    System.err.println("Usage: minigit checkout <commit_hash>");
                    System.exit(1);
                }
                checkout(args[1]);
                break;
            case "reset":
                if (args.length < 2) {
                    System.err.println("Usage: minigit reset <commit_hash>");
                    System.exit(1);
                }
                reset(args[1]);
                break;
            case "rm":
                if (args.length < 2) {
                    System.err.println("Usage: minigit rm <file>");
                    System.exit(1);
                }
                rm(args[1]);
                break;
            case "show":
                if (args.length < 2) {
                    System.err.println("Usage: minigit show <commit_hash>");
                    System.exit(1);
                }
                show(args[1]);
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

    static void status() throws Exception {
        Path indexPath = Paths.get(INDEX_FILE);
        List<String> lines = new ArrayList<>();
        if (Files.exists(indexPath) && Files.size(indexPath) > 0) {
            for (String line : Files.readAllLines(indexPath)) {
                if (!line.trim().isEmpty()) {
                    lines.add(line.trim());
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

    static Map<String, String> parseCommitFiles(String commitHash) throws Exception {
        Path commitPath = Paths.get(COMMITS_DIR, commitHash);
        if (!Files.exists(commitPath)) {
            return null;
        }
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : Files.readAllLines(commitPath)) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.trim().isEmpty()) {
                String[] parts = line.split(" ", 2);
                if (parts.length == 2) {
                    files.put(parts[0], parts[1]);
                }
            }
        }
        return files;
    }

    static void diff(String commit1, String commit2) throws Exception {
        Map<String, String> files1 = parseCommitFiles(commit1);
        Map<String, String> files2 = parseCommitFiles(commit2);
        if (files1 == null || files2 == null) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
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

    static void checkout(String commitHash) throws Exception {
        Path commitPath = Paths.get(COMMITS_DIR, commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files = parseCommitFiles(commitHash);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] content = Files.readAllBytes(Paths.get(OBJECTS_DIR, entry.getValue()));
            Files.write(Paths.get(entry.getKey()), content);
        }
        Files.write(Paths.get(HEAD_FILE), commitHash.getBytes());
        Files.write(Paths.get(INDEX_FILE), new byte[0]);
        System.out.println("Checked out " + commitHash);
    }

    static void reset(String commitHash) throws Exception {
        Path commitPath = Paths.get(COMMITS_DIR, commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.write(Paths.get(HEAD_FILE), commitHash.getBytes());
        Files.write(Paths.get(INDEX_FILE), new byte[0]);
        System.out.println("Reset to " + commitHash);
    }

    static void rm(String filename) throws Exception {
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
            System.out.println("File not in index");
            System.exit(1);
        }
        lines.remove(filename);
        StringBuilder sb = new StringBuilder();
        for (String l : lines) {
            sb.append(l).append("\n");
        }
        Files.write(indexPath, sb.toString().getBytes());
    }

    static void show(String commitHash) throws Exception {
        Path commitPath = Paths.get(COMMITS_DIR, commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String timestamp = "";
        String msg = "";
        boolean inFiles = false;
        List<String> fileLines = new ArrayList<>();
        for (String line : Files.readAllLines(commitPath)) {
            if (line.startsWith("timestamp: ")) {
                timestamp = line.substring(11);
            } else if (line.startsWith("message: ")) {
                msg = line.substring(9);
            } else if (line.equals("files:")) {
                inFiles = true;
            } else if (inFiles && !line.trim().isEmpty()) {
                fileLines.add(line.trim());
            }
        }
        Collections.sort(fileLines);
        System.out.println("commit " + commitHash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + msg);
        System.out.println("Files:");
        for (String fl : fileLines) {
            System.out.println("  " + fl);
        }
    }
}
