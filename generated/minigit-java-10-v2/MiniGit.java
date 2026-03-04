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

    static void status() throws Exception {
        String indexContent = new String(Files.readAllBytes(INDEX)).trim();
        System.out.println("Staged files:");
        if (indexContent.isEmpty()) {
            System.out.println("(none)");
        } else {
            for (String f : indexContent.split("\n")) {
                System.out.println(f);
            }
        }
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

    static Map<String, String> parseCommitFiles(String commitContent) {
        Map<String, String> files = new TreeMap<>();
        String[] lines = commitContent.split("\n");
        boolean inFiles = false;
        for (String line : lines) {
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

    static void diff(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("Usage: minigit diff <commit1> <commit2>");
            System.exit(1);
        }
        Path c1 = COMMITS.resolve(args[1]);
        Path c2 = COMMITS.resolve(args[2]);
        if (!Files.exists(c1) || !Files.exists(c2)) {
            System.out.println("Invalid commit");
            System.exit(1);
        }
        Map<String, String> files1 = parseCommitFiles(new String(Files.readAllBytes(c1)));
        Map<String, String> files2 = parseCommitFiles(new String(Files.readAllBytes(c2)));

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
        String indexContent = new String(Files.readAllBytes(INDEX)).trim();
        if (indexContent.isEmpty()) {
            System.out.println("File not in index");
            System.exit(1);
        }
        List<String> entries = new ArrayList<>(Arrays.asList(indexContent.split("\n")));
        if (!entries.remove(filename)) {
            System.out.println("File not in index");
            System.exit(1);
        }
        StringBuilder sb = new StringBuilder();
        for (String e : entries) {
            sb.append(e).append("\n");
        }
        Files.write(INDEX, sb.toString().getBytes());
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
        String[] lines = content.split("\n");
        String timestamp = "";
        String message = "";
        for (String line : lines) {
            if (line.startsWith("timestamp: ")) timestamp = line.substring(11);
            else if (line.startsWith("message: ")) message = line.substring(9);
        }
        Map<String, String> files = parseCommitFiles(content);
        System.out.println("commit " + hash);
        System.out.println("Date: " + timestamp);
        System.out.println("Message: " + message);
        System.out.println("Files:");
        for (Map.Entry<String, String> entry : files.entrySet()) {
            System.out.println("  " + entry.getKey() + " " + entry.getValue());
        }
    }
}
