import java.io.*;
import java.nio.file.*;
import java.util.*;

public class MiniGit {

    static final String DIR = ".minigit";
    static final String OBJECTS = DIR + "/objects";
    static final String COMMITS = DIR + "/commits";
    static final String INDEX = DIR + "/index";
    static final String HEAD = DIR + "/HEAD";

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            System.err.println("Usage: minigit <command>");
            System.exit(1);
        }
        String cmd = args[0];
        switch (cmd) {
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
                System.err.println("Unknown command: " + cmd);
                System.exit(1);
        }
    }

    static void doInit() throws Exception {
        if (Files.isDirectory(Paths.get(DIR))) {
            System.out.println("Repository already initialized");
            return;
        }
        Files.createDirectories(Paths.get(OBJECTS));
        Files.createDirectories(Paths.get(COMMITS));
        Files.write(Paths.get(INDEX), new byte[0]);
        Files.write(Paths.get(HEAD), new byte[0]);
    }

    static void doAdd(String filename) throws Exception {
        Path filePath = Paths.get(filename);
        if (!Files.exists(filePath)) {
            System.out.println("File not found");
            System.exit(1);
        }
        byte[] content = Files.readAllBytes(filePath);
        String hash = miniHash(content);
        Files.write(Paths.get(OBJECTS + "/" + hash), content);

        // Read index, add if not present
        List<String> lines = readLines(INDEX);
        if (!lines.contains(filename)) {
            lines.add(filename);
            writeLines(INDEX, lines);
        }
    }

    static void doCommit(String message) throws Exception {
        List<String> indexLines = readLines(INDEX);
        if (indexLines.isEmpty()) {
            System.out.println("Nothing to commit");
            System.exit(1);
        }

        String parent = new String(Files.readAllBytes(Paths.get(HEAD))).trim();
        if (parent.isEmpty()) {
            parent = "NONE";
        }

        long timestamp = System.currentTimeMillis() / 1000;

        // Build file entries: for each file in index, get its blob hash
        List<String> sortedFiles = new ArrayList<>(indexLines);
        Collections.sort(sortedFiles);

        StringBuilder sb = new StringBuilder();
        sb.append("parent: ").append(parent).append("\n");
        sb.append("timestamp: ").append(timestamp).append("\n");
        sb.append("message: ").append(message).append("\n");
        sb.append("files:\n");
        for (String fname : sortedFiles) {
            byte[] content = Files.readAllBytes(Paths.get(fname));
            String blobHash = miniHash(content);
            sb.append(fname).append(" ").append(blobHash).append("\n");
        }

        String commitContent = sb.toString();
        String commitHash = miniHash(commitContent.getBytes());

        Files.write(Paths.get(COMMITS + "/" + commitHash), commitContent.getBytes());
        Files.write(Paths.get(HEAD), commitHash.getBytes());
        // Clear index
        Files.write(Paths.get(INDEX), new byte[0]);

        System.out.println("Committed " + commitHash);
    }

    static void doLog() throws Exception {
        String hash = new String(Files.readAllBytes(Paths.get(HEAD))).trim();
        if (hash.isEmpty()) {
            System.out.println("No commits");
            return;
        }

        boolean first = true;
        while (!hash.isEmpty() && !hash.equals("NONE")) {
            if (!first) {
                System.out.println();
            }
            first = false;

            String content = new String(Files.readAllBytes(Paths.get(COMMITS + "/" + hash)));
            String[] lines = content.split("\n");
            String parentVal = "";
            String timestampVal = "";
            String messageVal = "";
            for (String line : lines) {
                if (line.startsWith("parent: ")) {
                    parentVal = line.substring(8);
                } else if (line.startsWith("timestamp: ")) {
                    timestampVal = line.substring(11);
                } else if (line.startsWith("message: ")) {
                    messageVal = line.substring(9);
                }
            }

            System.out.println("commit " + hash);
            System.out.println("Date: " + timestampVal);
            System.out.println("Message: " + messageVal);

            hash = parentVal;
        }
    }

    static String miniHash(byte[] data) {
        long h = 1469598103934665603L;
        for (byte b : data) {
            h = h ^ (b & 0xFF);
            h = h * 1099511628211L; // overflow gives mod 2^64
        }
        return String.format("%016x", h);
    }

    static List<String> readLines(String path) throws Exception {
        List<String> result = new ArrayList<>();
        String content = new String(Files.readAllBytes(Paths.get(path)));
        if (content.trim().isEmpty()) {
            return result;
        }
        for (String line : content.split("\n")) {
            String trimmed = line.trim();
            if (!trimmed.isEmpty()) {
                result.add(trimmed);
            }
        }
        return result;
    }

    static void writeLines(String path, List<String> lines) throws Exception {
        StringBuilder sb = new StringBuilder();
        for (String line : lines) {
            sb.append(line).append("\n");
        }
        Files.write(Paths.get(path), sb.toString().getBytes());
    }
}
