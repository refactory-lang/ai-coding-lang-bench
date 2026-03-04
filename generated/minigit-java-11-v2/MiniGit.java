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
        if (args.length == 0) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }
        switch (args[0]) {
            case "init": doInit(); break;
            case "add": doAdd(args); break;
            case "commit": doCommit(args); break;
            case "status": doStatus(); break;
            case "log": doLog(); break;
            case "diff": doDiff(args); break;
            case "checkout": doCheckout(args); break;
            case "reset": doReset(args); break;
            case "rm": doRm(args); break;
            case "show": doShow(args); break;
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

    private static void doInit() throws Exception {
        if (Files.exists(MINIGIT_DIR)) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(OBJECTS_DIR);
        Files.createDirectories(COMMITS_DIR);
        Files.write(INDEX_FILE, new byte[0]);
        Files.write(HEAD_FILE, new byte[0]);
    }

    private static void doAdd(String[] args) throws Exception {
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
        Files.write(OBJECTS_DIR.resolve(hash), content);

        List<String> entries = readIndex();
        if (!entries.contains(filename)) {
            entries.add(filename);
            writeIndex(entries);
        }
    }

    private static void doCommit(String[] args) throws Exception {
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

        List<String> indexEntries = readIndex();
        if (indexEntries.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        List<String> filenames = indexEntries.stream().sorted().collect(Collectors.toList());

        String headContent = new String(Files.readAllBytes(HEAD_FILE)).trim();
        String parent = headContent.isEmpty() ? "NONE" : headContent;

        long timestamp = System.currentTimeMillis() / 1000;

        StringBuilder commitContent = new StringBuilder();
        commitContent.append("parent: ").append(parent).append("\n");
        commitContent.append("timestamp: ").append(timestamp).append("\n");
        commitContent.append("message: ").append(message).append("\n");
        commitContent.append("files:\n");

        for (String filename : filenames) {
            byte[] content = Files.readAllBytes(Paths.get(filename));
            String blobHash = miniHash(content);
            commitContent.append(filename).append(" ").append(blobHash).append("\n");
        }

        String commitStr = commitContent.toString();
        String commitHash = miniHash(commitStr.getBytes());

        Files.write(COMMITS_DIR.resolve(commitHash), commitStr.getBytes());
        Files.write(HEAD_FILE, commitHash.getBytes());
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    private static void doStatus() throws Exception {
        List<String> entries = readIndex();
        System.out.println("Staged files:");
        if (entries.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String entry : entries) {
                System.out.println(entry);
            }
        }
    }

    private static void doLog() throws Exception {
        String head = new String(Files.readAllBytes(HEAD_FILE)).trim();
        if (head.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        String current = head;
        while (!current.equals("NONE") && !current.isEmpty()) {
            String commitContent = new String(Files.readAllBytes(COMMITS_DIR.resolve(current)));
            String[] lines = commitContent.split("\n");
            String parentHash = "NONE";
            String timestamp = "";
            String message = "";
            for (String line : lines) {
                if (line.startsWith("parent: ")) parentHash = line.substring(8);
                else if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
                else if (line.startsWith("message: ")) message = line.substring(9);
            }
            System.out.println("commit " + current);
            System.out.println("Date: " + timestamp);
            System.out.println("Message: " + message);
            System.out.println();
            current = parentHash;
        }
    }

    private static void doDiff(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("Usage: minigit diff <commit1> <commit2>");
            System.exit(1);
        }
        String hash1 = args[1];
        String hash2 = args[2];

        Path commitPath1 = COMMITS_DIR.resolve(hash1);
        Path commitPath2 = COMMITS_DIR.resolve(hash2);

        if (!Files.exists(commitPath1) || !Files.exists(commitPath2)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Map<String, String> files1 = parseCommitFiles(new String(Files.readAllBytes(commitPath1)));
        Map<String, String> files2 = parseCommitFiles(new String(Files.readAllBytes(commitPath2)));

        Set<String> allFiles = new TreeSet<>();
        allFiles.addAll(files1.keySet());
        allFiles.addAll(files2.keySet());

        for (String file : allFiles) {
            String blob1 = files1.get(file);
            String blob2 = files2.get(file);
            if (blob1 == null) {
                System.out.println("Added: " + file);
            } else if (blob2 == null) {
                System.out.println("Removed: " + file);
            } else if (!blob1.equals(blob2)) {
                System.out.println("Modified: " + file);
            }
        }
    }

    private static void doCheckout(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit checkout <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitPath = COMMITS_DIR.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        String commitContent = new String(Files.readAllBytes(commitPath));
        Map<String, String> files = parseCommitFiles(commitContent);

        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blobContent = Files.readAllBytes(OBJECTS_DIR.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blobContent);
        }

        Files.write(HEAD_FILE, hash.getBytes());
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Checked out " + hash);
    }

    private static void doReset(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit reset <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitPath = COMMITS_DIR.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Files.write(HEAD_FILE, hash.getBytes());
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Reset to " + hash);
    }

    private static void doRm(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit rm <file>");
            System.exit(1);
        }
        String filename = args[1];
        List<String> entries = readIndex();
        if (!entries.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        entries.remove(filename);
        writeIndex(entries);
    }

    private static void doShow(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit show <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitPath = COMMITS_DIR.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        String commitContent = new String(Files.readAllBytes(commitPath));
        String[] lines = commitContent.split("\n");
        String timestamp = "";
        String message = "";
        for (String line : lines) {
            if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
            else if (line.startsWith("message: ")) message = line.substring(9);
        }

        Map<String, String> files = parseCommitFiles(commitContent);

        System.out.println("commit " + hash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : new TreeMap<>(files).entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    private static Map<String, String> parseCommitFiles(String commitContent) {
        Map<String, String> files = new LinkedHashMap<>();
        String[] lines = commitContent.split("\n");
        boolean inFiles = false;
        for (String line : lines) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.isEmpty()) {
                String[] parts = line.split(" ", 2);
                if (parts.length == 2) {
                    files.put(parts[0], parts[1]);
                }
            }
        }
        return files;
    }

    private static List<String> readIndex() throws Exception {
        String indexContent = new String(Files.readAllBytes(INDEX_FILE)).trim();
        if (indexContent.isEmpty()) {
            return new ArrayList<>();
        }
        return new ArrayList<>(Arrays.asList(indexContent.split("\n")));
    }

    private static void writeIndex(List<String> entries) throws Exception {
        if (entries.isEmpty()) {
            Files.write(INDEX_FILE, new byte[0]);
        } else {
            Files.write(INDEX_FILE, (String.join("\n", entries) + "\n").getBytes());
        }
    }
}
