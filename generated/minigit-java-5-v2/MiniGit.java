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
            case "status": status(); break;
            case "log": log(); break;
            case "diff": diff(args); break;
            case "checkout": checkout(args); break;
            case "reset": reset(args); break;
            case "rm": rm(args); break;
            case "show": show(args); break;
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

    static void status() throws Exception {
        List<String> indexLines = readLines(INDEX);
        System.out.println("Staged files:");
        if (indexLines.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : indexLines) {
                System.out.println(f);
            }
        }
    }

    static void diff(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("Usage: minigit diff <commit1> <commit2>");
            System.exit(1);
        }
        Path c1Path = COMMITS.resolve(args[1]);
        Path c2Path = COMMITS.resolve(args[2]);
        if (!Files.exists(c1Path) || !Files.exists(c2Path)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files1 = parseCommitFiles(new String(Files.readAllBytes(c1Path)));
        Map<String, String> files2 = parseCommitFiles(new String(Files.readAllBytes(c2Path)));
        TreeSet<String> allFiles = new TreeSet<>();
        allFiles.addAll(files1.keySet());
        allFiles.addAll(files2.keySet());
        for (String f : allFiles) {
            boolean in1 = files1.containsKey(f);
            boolean in2 = files2.containsKey(f);
            if (in1 && in2) {
                if (!files1.get(f).equals(files2.get(f))) {
                    System.out.println("Modified: " + f);
                }
            } else if (!in1 && in2) {
                System.out.println("Added: " + f);
            } else if (in1 && !in2) {
                System.out.println("Removed: " + f);
            }
        }
    }

    static void checkout(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit checkout <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitFile = COMMITS.resolve(hash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = new String(Files.readAllBytes(commitFile));
        Map<String, String> files = parseCommitFiles(content);
        for (Map.Entry<String, String> entry : files.entrySet()) {
            byte[] blob = Files.readAllBytes(OBJECTS.resolve(entry.getValue()));
            Files.write(Paths.get(entry.getKey()), blob);
        }
        Files.write(HEAD, hash.getBytes());
        Files.write(INDEX, new byte[0]);
        System.out.println("Checked out " + hash);
    }

    static void reset(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit reset <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitFile = COMMITS.resolve(hash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Files.write(HEAD, hash.getBytes());
        Files.write(INDEX, new byte[0]);
        System.out.println("Reset to " + hash);
    }

    static void rm(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit rm <file>");
            System.exit(1);
        }
        String filename = args[1];
        List<String> lines = readLines(INDEX);
        if (!lines.contains(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        lines.remove(filename);
        if (lines.isEmpty()) {
            Files.write(INDEX, new byte[0]);
        } else {
            Files.write(INDEX, String.join("\n", lines).concat("\n").getBytes());
        }
    }

    static void show(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: minigit show <commit_hash>");
            System.exit(1);
        }
        String hash = args[1];
        Path commitFile = COMMITS.resolve(hash);
        if (!Files.exists(commitFile)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        String content = new String(Files.readAllBytes(commitFile));
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
        for (Map.Entry<String, String> entry : new TreeMap<>(files).entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }

    static Map<String, String> parseCommitFiles(String commitContent) {
        Map<String, String> files = new TreeMap<>();
        boolean inFiles = false;
        for (String line : commitContent.split("\n")) {
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
