package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func minihash(data []byte) string {
	h := uint64(1469598103934665603)
	for _, b := range data {
		h ^= uint64(b)
		h *= 1099511628211
	}
	return fmt.Sprintf("%016x", h)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: minigit <command>")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "init":
		cmdInit()
	case "add":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit add <file>")
			os.Exit(1)
		}
		cmdAdd(os.Args[2])
	case "commit":
		if len(os.Args) < 4 || os.Args[2] != "-m" {
			fmt.Fprintln(os.Stderr, "Usage: minigit commit -m \"<message>\"")
			os.Exit(1)
		}
		cmdCommit(os.Args[3])
	case "status":
		cmdStatus()
	case "log":
		cmdLog()
	case "diff":
		if len(os.Args) < 4 {
			fmt.Fprintln(os.Stderr, "Usage: minigit diff <commit1> <commit2>")
			os.Exit(1)
		}
		cmdDiff(os.Args[2], os.Args[3])
	case "checkout":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit checkout <commit_hash>")
			os.Exit(1)
		}
		cmdCheckout(os.Args[2])
	case "reset":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit reset <commit_hash>")
			os.Exit(1)
		}
		cmdReset(os.Args[2])
	case "rm":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit rm <file>")
			os.Exit(1)
		}
		cmdRm(os.Args[2])
	case "show":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: minigit show <commit_hash>")
			os.Exit(1)
		}
		cmdShow(os.Args[2])
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}

func cmdInit() {
	if _, err := os.Stat(".minigit"); err == nil {
		fmt.Println("Repository already initialized")
		return
	}
	os.MkdirAll(filepath.Join(".minigit", "objects"), 0755)
	os.MkdirAll(filepath.Join(".minigit", "commits"), 0755)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte{}, 0644)
}

func cmdAdd(filename string) {
	data, err := os.ReadFile(filename)
	if err != nil {
		fmt.Println("File not found")
		os.Exit(1)
	}

	hash := minihash(data)
	os.WriteFile(filepath.Join(".minigit", "objects", hash), data, 0644)

	// Read index and add filename if not present
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	lines := []string{}
	if len(indexData) > 0 {
		for _, l := range strings.Split(string(indexData), "\n") {
			if l != "" {
				lines = append(lines, l)
			}
		}
	}

	found := false
	for _, l := range lines {
		if l == filename {
			found = true
			break
		}
	}
	if !found {
		lines = append(lines, filename)
	}

	os.WriteFile(filepath.Join(".minigit", "index"), []byte(strings.Join(lines, "\n")+"\n"), 0644)
}

func cmdCommit(message string) {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	lines := []string{}
	for _, l := range strings.Split(string(indexData), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}

	if len(lines) == 0 {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}

	sort.Strings(lines)

	// Build file entries
	var fileEntries []string
	for _, fname := range lines {
		data, err := os.ReadFile(filepath.Join(".minigit", "objects", blobHashForFile(fname)))
		if err != nil {
			// Read from working dir and hash
			data, _ = os.ReadFile(fname)
		} else {
			_ = data
		}
		fileEntries = append(fileEntries, fmt.Sprintf("%s %s", fname, blobHashForFile(fname)))
	}

	headData, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	parent := strings.TrimSpace(string(headData))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := time.Now().Unix()

	content := fmt.Sprintf("parent: %s\ntimestamp: %d\nmessage: %s\nfiles:\n%s\n",
		parent, timestamp, message, strings.Join(fileEntries, "\n"))

	commitHash := minihash([]byte(content))
	os.WriteFile(filepath.Join(".minigit", "commits", commitHash), []byte(content), 0644)
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Printf("Committed %s\n", commitHash)
}

func blobHashForFile(filename string) string {
	data, err := os.ReadFile(filename)
	if err != nil {
		return ""
	}
	return minihash(data)
}

func cmdLog() {
	headData, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	current := strings.TrimSpace(string(headData))

	if current == "" {
		fmt.Println("No commits")
		return
	}

	first := true
	for current != "" && current != "NONE" {
		commitData, err := os.ReadFile(filepath.Join(".minigit", "commits", current))
		if err != nil {
			break
		}

		lines := strings.Split(string(commitData), "\n")
		var parent, timestamp, message string
		for _, l := range lines {
			if strings.HasPrefix(l, "parent: ") {
				parent = strings.TrimPrefix(l, "parent: ")
			} else if strings.HasPrefix(l, "timestamp: ") {
				timestamp = strings.TrimPrefix(l, "timestamp: ")
			} else if strings.HasPrefix(l, "message: ") {
				message = strings.TrimPrefix(l, "message: ")
			}
		}

		if !first {
			fmt.Println()
		}
		fmt.Printf("commit %s\n", current)
		fmt.Printf("Date: %s\n", timestamp)
		fmt.Printf("Message: %s\n", message)

		first = false
		current = parent
	}
}

func cmdStatus() {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	lines := []string{}
	for _, l := range strings.Split(string(indexData), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}

	fmt.Println("Staged files:")
	if len(lines) == 0 {
		fmt.Println("(none)")
	} else {
		for _, l := range lines {
			fmt.Println(l)
		}
	}
}

func parseCommitFiles(commitData string) map[string]string {
	files := make(map[string]string)
	inFiles := false
	for _, l := range strings.Split(commitData, "\n") {
		if l == "files:" {
			inFiles = true
			continue
		}
		if inFiles && l != "" {
			parts := strings.SplitN(l, " ", 2)
			if len(parts) == 2 {
				files[parts[0]] = parts[1]
			}
		}
	}
	return files
}

func cmdDiff(hash1, hash2 string) {
	data1, err1 := os.ReadFile(filepath.Join(".minigit", "commits", hash1))
	if err1 != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}
	data2, err2 := os.ReadFile(filepath.Join(".minigit", "commits", hash2))
	if err2 != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	files1 := parseCommitFiles(string(data1))
	files2 := parseCommitFiles(string(data2))

	// Collect all filenames
	allFiles := make(map[string]bool)
	for f := range files1 {
		allFiles[f] = true
	}
	for f := range files2 {
		allFiles[f] = true
	}

	sorted := make([]string, 0, len(allFiles))
	for f := range allFiles {
		sorted = append(sorted, f)
	}
	sort.Strings(sorted)

	for _, f := range sorted {
		h1, in1 := files1[f]
		h2, in2 := files2[f]
		if in1 && !in2 {
			fmt.Printf("Removed: %s\n", f)
		} else if !in1 && in2 {
			fmt.Printf("Added: %s\n", f)
		} else if h1 != h2 {
			fmt.Printf("Modified: %s\n", f)
		}
	}
}

func cmdCheckout(hash string) {
	commitData, err := os.ReadFile(filepath.Join(".minigit", "commits", hash))
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	files := parseCommitFiles(string(commitData))
	for fname, blobHash := range files {
		blobData, err := os.ReadFile(filepath.Join(".minigit", "objects", blobHash))
		if err != nil {
			continue
		}
		os.WriteFile(fname, blobData, 0644)
	}

	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(hash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Printf("Checked out %s\n", hash)
}

func cmdReset(hash string) {
	if _, err := os.ReadFile(filepath.Join(".minigit", "commits", hash)); err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(hash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Printf("Reset to %s\n", hash)
}

func cmdRm(filename string) {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	lines := []string{}
	for _, l := range strings.Split(string(indexData), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}

	found := false
	var newLines []string
	for _, l := range lines {
		if l == filename {
			found = true
		} else {
			newLines = append(newLines, l)
		}
	}

	if !found {
		fmt.Println("File not in index")
		os.Exit(1)
	}

	content := ""
	if len(newLines) > 0 {
		content = strings.Join(newLines, "\n") + "\n"
	}
	os.WriteFile(filepath.Join(".minigit", "index"), []byte(content), 0644)
}

func cmdShow(hash string) {
	commitData, err := os.ReadFile(filepath.Join(".minigit", "commits", hash))
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	lines := strings.Split(string(commitData), "\n")
	var timestamp, message string
	for _, l := range lines {
		if strings.HasPrefix(l, "timestamp: ") {
			timestamp = strings.TrimPrefix(l, "timestamp: ")
		} else if strings.HasPrefix(l, "message: ") {
			message = strings.TrimPrefix(l, "message: ")
		}
	}

	files := parseCommitFiles(string(commitData))
	sorted := make([]string, 0, len(files))
	for f := range files {
		sorted = append(sorted, f)
	}
	sort.Strings(sorted)

	fmt.Printf("commit %s\n", hash)
	fmt.Printf("Date: %s\n", timestamp)
	fmt.Printf("Message: %s\n", message)
	fmt.Println("Files:")
	for _, f := range sorted {
		fmt.Printf("  %s %s\n", f, files[f])
	}
}
