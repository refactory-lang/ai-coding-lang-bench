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
            case "status":
                doStatus();
                break;
            case "log":
                doLog();
                break;
            case "diff":
                if (args.length < 3) { System.err.println("Usage: minigit diff <c1> <c2>"); System.exit(1); }
                doDiff(args[1], args[2]);
                break;
            case "checkout":
                if (args.length < 2) { System.err.println("Usage: minigit checkout <hash>"); System.exit(1); }
                doCheckout(args[1]);
                break;
            case "reset":
                if (args.length < 2) { System.err.println("Usage: minigit reset <hash>"); System.exit(1); }
                doReset(args[1]);
                break;
            case "rm":
                if (args.length < 2) { System.err.println("Usage: minigit rm <file>"); System.exit(1); }
                doRm(args[1]);
                break;
            case "show":
                if (args.length < 2) { System.err.println("Usage: minigit show <hash>"); System.exit(1); }
                doShow(args[1]);
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

    static void doStatus() throws Exception {
        List<String> entries = readIndex();
        System.out.println("Staged files:");
        if (entries.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String e : entries) {
                System.out.println(e);
            }
        }
    }

    static Map<String, String> parseCommitFiles(String content) {
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : content.split("\n")) {
            if (line.equals("files:")) { inFiles = true; continue; }
            if (inFiles && !line.isEmpty()) {
                String[] parts = line.split(" ", 2);
                if (parts.length == 2) files.put(parts[0], parts[1]);
            }
        }
        return files;
    }

    static void doDiff(String hash1, String hash2) throws Exception {
        Path c1 = COMMITS.resolve(hash1);
        Path c2 = COMMITS.resolve(hash2);
        if (!Files.exists(c1) || !Files.exists(c2)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> f1 = parseCommitFiles(new String(Files.readAllBytes(c1)));
        Map<String, String> f2 = parseCommitFiles(new String(Files.readAllBytes(c2)));

        Set<String> allFiles = new TreeSet<>();
        allFiles.addAll(f1.keySet());
        allFiles.addAll(f2.keySet());

        for (String f : allFiles) {
            String h1 = f1.get(f);
            String h2 = f2.get(f);
            if (h1 == null) {
                System.out.println("Added: " + f);
            } else if (h2 == null) {
                System.out.println("Removed: " + f);
            } else if (!h1.equals(h2)) {
                System.out.println("Modified: " + f);
            }
        }
    }

    static void doCheckout(String hash) throws Exception {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = new String(Files.readAllBytes(commitPath));
        Map<String, String> files = parseCommitFiles(content);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blob = Files.readAllBytes(OBJECTS.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blob);
        }
        Files.write(HEAD, hash.getBytes());
        Files.write(INDEX, new byte[0]);
        System.out.println("Checked out " + hash);
    }

    static void doReset(String hash) throws Exception {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.write(HEAD, hash.getBytes());
        Files.write(INDEX, new byte[0]);
        System.out.println("Reset to " + hash);
    }

    static void doRm(String filename) throws Exception {
        List<String> entries = readIndex();
        if (!entries.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        entries.remove(filename);
        if (entries.isEmpty()) {
            Files.write(INDEX, new byte[0]);
        } else {
            Files.write(INDEX, String.join("\n", entries).concat("\n").getBytes());
        }
    }

    static void doShow(String hash) throws Exception {
        Path commitPath = COMMITS.resolve(hash);
        if (!Files.exists(commitPath)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = new String(Files.readAllBytes(commitPath));
        String ts = "", msg = "";
        for (String line : content.split("\n")) {
            if (line.startsWith("timestamp: ")) ts = line.substring(11);
            else if (line.startsWith("message: ")) msg = line.substring(9);
        }
        Map<String, String> files = parseCommitFiles(content);
        System.out.println("commit " + hash);
        System.out.println("Date: " + ts);
        System.out.println("Message: " + msg);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : files.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
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
