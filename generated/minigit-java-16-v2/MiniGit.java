import java.io.*;
import java.nio.file.*;
import java.util.*;

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

    private static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
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

    private static void doAdd(String filename) throws Exception {
        Path file = Paths.get(filename);
        if (!Files.exists(file)) {
            System.out.println("File not found");
            System.exit(1);
        }

        byte[] content = Files.readAllBytes(file);
        String hash = miniHash(content);

        Files.write(OBJECTS_DIR.resolve(hash), content);

        List<String> indexLines = readIndex();
        if (!indexLines.contains(filename)) {
            indexLines.add(filename);
            Files.write(INDEX_FILE, String.join("\n", indexLines).getBytes());
        }
    }

    private static void doCommit(String message) throws Exception {
        List<String> indexLines = readIndex();
        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String head = new String(Files.readAllBytes(HEAD_FILE)).trim();
        String parent = head.isEmpty() ? "NONE" : head;
        long timestamp = System.currentTimeMillis() / 1000;

        Collections.sort(indexLines);

        StringBuilder filesSection = new StringBuilder();
        for (String fname : indexLines) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String hash = miniHash(content);
            filesSection.append(fname).append(" ").append(hash).append("\n");
        }

        String commitContent = "parent: " + parent + "\n" +
                "timestamp: " + timestamp + "\n" +
                "message: " + message + "\n" +
                "files:\n" +
                filesSection.toString();

        String commitHash = miniHash(commitContent.getBytes());

        Files.write(COMMITS_DIR.resolve(commitHash), commitContent.getBytes());
        Files.write(HEAD_FILE, commitHash.getBytes());
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    private static void doStatus() throws Exception {
        List<String> indexLines = readIndex();
        System.out.println("Staged files:");
        if (indexLines.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : indexLines) {
                System.out.println(f);
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
            Path commitPath = COMMITS_DIR.resolve(current);
            String content = new String(Files.readAllBytes(commitPath));
            Map<String, String> fields = parseCommitHeader(content);

            System.out.println("commit " + current);
            System.out.println("Date: " + fields.get("timestamp"));
            System.out.println("Message: " + fields.get("message"));
            System.out.println();

            current = fields.get("parent");
        }
    }

    private static void doDiff(String hash1, String hash2) throws Exception {
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

        for (String fname : allFiles) {
            String blob1 = files1.get(fname);
            String blob2 = files2.get(fname);
            if (blob1 == null) {
                System.out.println("Added: " + fname);
            } else if (blob2 == null) {
                System.out.println("Removed: " + fname);
            } else if (!blob1.equals(blob2)) {
                System.out.println("Modified: " + fname);
            }
        }
    }

    private static void doCheckout(String commitHash) throws Exception {
        Path commitPath = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Map<String, String> files = parseCommitFiles(new String(Files.readAllBytes(commitPath)));

        for (Map.Entry<String, String> entry : files.entrySet()) {
            String filename = entry.getKey();
            String blobHash = entry.getValue();
            byte[] blobContent = Files.readAllBytes(OBJECTS_DIR.resolve(blobHash));
            Files.write(Paths.get(filename), blobContent);
        }

        Files.write(HEAD_FILE, commitHash.getBytes());
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Checked out " + commitHash);
    }

    private static void doReset(String commitHash) throws Exception {
        Path commitPath = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        Files.write(HEAD_FILE, commitHash.getBytes());
        Files.write(INDEX_FILE, new byte[0]);

        System.out.println("Reset to " + commitHash);
    }

    private static void doRm(String filename) throws Exception {
        List<String> indexLines = readIndex();
        if (!indexLines.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        indexLines.remove(filename);
        if (indexLines.isEmpty()) {
            Files.write(INDEX_FILE, new byte[0]);
        } else {
            Files.write(INDEX_FILE, String.join("\n", indexLines).getBytes());
        }
    }

    private static void doShow(String commitHash) throws Exception {
        Path commitPath = COMMITS_DIR.resolve(commitHash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }

        String content = new String(Files.readAllBytes(commitPath));
        Map<String, String> fields = parseCommitHeader(content);
        Map<String, String> files = parseCommitFiles(content);

        System.out.println("commit " + commitHash);
        System.out.println("Date: " + fields.get("timestamp"));
        System.out.println("Message: " + fields.get("message"));
        System.out.println("Files:");

        TreeMap<String, String> sortedFiles = new TreeMap<>(files);
        for (Map.Entry<String, String> entry : sortedFiles.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    private static Map<String, String> parseCommitHeader(String content) {
        Map<String, String> fields = new HashMap<>();
        String[] lines = content.split("\n");
        for (String line : lines) {
            if (line.startsWith("parent: ")) {
                fields.put("parent", line.substring(8));
            } else if (line.startsWith("timestamp: ")) {
                fields.put("timestamp", line.substring(11));
            } else if (line.startsWith("message: ")) {
                fields.put("message", line.substring(9));
            } else if (line.equals("files:")) {
                break;
            }
        }
        return fields;
    }

    private static Map<String, String> parseCommitFiles(String content) {
        Map<String, String> files = new LinkedHashMap<>();
        String[] lines = content.split("\n");
        boolean inFiles = false;
        for (String line : lines) {
            if (line.equals("files:")) {
                inFiles = true;
                continue;
            }
            if (inFiles && !line.isEmpty()) {
                int spaceIdx = line.indexOf(' ');
                if (spaceIdx > 0) {
                    files.put(line.substring(0, spaceIdx), line.substring(spaceIdx + 1));
                }
            }
        }
        return files;
    }

    private static List<String> readIndex() throws Exception {
        if (!Files.exists(INDEX_FILE)) {
            return new ArrayList<>();
        }
        String content = new String(Files.readAllBytes(INDEX_FILE)).trim();
        if (content.isEmpty()) {
            return new ArrayList<>();
        }
        return new ArrayList<>(Arrays.asList(content.split("\n")));
    }
}
