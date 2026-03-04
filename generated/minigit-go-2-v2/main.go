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
	var h uint64 = 1469598103934665603
	for _, b := range data {
		h ^= uint64(b)
		h *= 1099511628211
	}
	return fmt.Sprintf("%016x", h)
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

	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	indexStr := string(indexData)
	lines := []string{}
	if indexStr != "" {
		lines = strings.Split(strings.TrimRight(indexStr, "\n"), "\n")
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
		os.WriteFile(filepath.Join(".minigit", "index"), []byte(strings.Join(lines, "\n")+"\n"), 0644)
	}
}

func cmdCommit(message string) {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	if indexStr == "" {
		fmt.Println("Nothing to commit")
		os.Exit(1)
	}
	files := strings.Split(indexStr, "\n")
	sort.Strings(files)

	headData, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	parent := strings.TrimSpace(string(headData))
	if parent == "" {
		parent = "NONE"
	}

	timestamp := time.Now().Unix()

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("parent: %s\n", parent))
	sb.WriteString(fmt.Sprintf("timestamp: %d\n", timestamp))
	sb.WriteString(fmt.Sprintf("message: %s\n", message))
	sb.WriteString("files:\n")
	for _, f := range files {
		data, _ := os.ReadFile(f)
		hash := minihash(data)
		sb.WriteString(fmt.Sprintf("%s %s\n", f, hash))
	}

	content := sb.String()
	commitHash := minihash([]byte(content))

	os.WriteFile(filepath.Join(".minigit", "commits", commitHash), []byte(content), 0644)
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(commitHash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)

	fmt.Printf("Committed %s\n", commitHash)
}

func cmdLog() {
	headData, _ := os.ReadFile(filepath.Join(".minigit", "HEAD"))
	current := strings.TrimSpace(string(headData))
	if current == "" {
		fmt.Println("No commits")
		return
	}

	for current != "" && current != "NONE" {
		commitData, err := os.ReadFile(filepath.Join(".minigit", "commits", current))
		if err != nil {
			break
		}
		lines := strings.Split(string(commitData), "\n")
		var timestamp, message, parent string
		for _, line := range lines {
			if strings.HasPrefix(line, "parent: ") {
				parent = strings.TrimPrefix(line, "parent: ")
			} else if strings.HasPrefix(line, "timestamp: ") {
				timestamp = strings.TrimPrefix(line, "timestamp: ")
			} else if strings.HasPrefix(line, "message: ") {
				message = strings.TrimPrefix(line, "message: ")
			}
		}
		fmt.Printf("commit %s\n", current)
		fmt.Printf("Date: %s\n", timestamp)
		fmt.Printf("Message: %s\n", message)
		fmt.Println()
		current = parent
	}
}

func cmdStatus() {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	fmt.Println("Staged files:")
	if indexStr == "" {
		fmt.Println("(none)")
	} else {
		lines := strings.Split(indexStr, "\n")
		for _, l := range lines {
			fmt.Println(l)
		}
	}
}

func parseCommit(hash string) (parent, timestamp, message string, files [][2]string, err error) {
	data, err := os.ReadFile(filepath.Join(".minigit", "commits", hash))
	if err != nil {
		return "", "", "", nil, err
	}
	lines := strings.Split(string(data), "\n")
	inFiles := false
	for _, line := range lines {
		if inFiles {
			if line == "" {
				continue
			}
			parts := strings.SplitN(line, " ", 2)
			if len(parts) == 2 {
				files = append(files, [2]string{parts[0], parts[1]})
			}
		} else if strings.HasPrefix(line, "parent: ") {
			parent = strings.TrimPrefix(line, "parent: ")
		} else if strings.HasPrefix(line, "timestamp: ") {
			timestamp = strings.TrimPrefix(line, "timestamp: ")
		} else if strings.HasPrefix(line, "message: ") {
			message = strings.TrimPrefix(line, "message: ")
		} else if line == "files:" {
			inFiles = true
		}
	}
	return
}

func cmdDiff(hash1, hash2 string) {
	_, _, _, files1, err1 := parseCommit(hash1)
	if err1 != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}
	_, _, _, files2, err2 := parseCommit(hash2)
	if err2 != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}

	m1 := map[string]string{}
	for _, f := range files1 {
		m1[f[0]] = f[1]
	}
	m2 := map[string]string{}
	for _, f := range files2 {
		m2[f[0]] = f[1]
	}

	allFiles := map[string]bool{}
	for k := range m1 {
		allFiles[k] = true
	}
	for k := range m2 {
		allFiles[k] = true
	}
	sorted := []string{}
	for k := range allFiles {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)

	for _, f := range sorted {
		h1, in1 := m1[f]
		h2, in2 := m2[f]
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
	_, _, _, files, err := parseCommit(hash)
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}
	for _, f := range files {
		blobData, err := os.ReadFile(filepath.Join(".minigit", "objects", f[1]))
		if err != nil {
			continue
		}
		os.WriteFile(f[0], blobData, 0644)
	}
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(hash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)
	fmt.Printf("Checked out %s\n", hash)
}

func cmdReset(hash string) {
	_, err := os.Stat(filepath.Join(".minigit", "commits", hash))
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}
	os.WriteFile(filepath.Join(".minigit", "HEAD"), []byte(hash), 0644)
	os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)
	fmt.Printf("Reset to %s\n", hash)
}

func cmdRm(filename string) {
	indexData, _ := os.ReadFile(filepath.Join(".minigit", "index"))
	indexStr := strings.TrimRight(string(indexData), "\n")
	if indexStr == "" {
		fmt.Println("File not in index")
		os.Exit(1)
	}
	lines := strings.Split(indexStr, "\n")
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
	if len(newLines) == 0 {
		os.WriteFile(filepath.Join(".minigit", "index"), []byte{}, 0644)
	} else {
		os.WriteFile(filepath.Join(".minigit", "index"), []byte(strings.Join(newLines, "\n")+"\n"), 0644)
	}
}

func cmdShow(hash string) {
	_, timestamp, message, files, err := parseCommit(hash)
	if err != nil {
		fmt.Println("Invalid commit")
		os.Exit(1)
	}
	fmt.Printf("commit %s\n", hash)
	fmt.Printf("Date: %s\n", timestamp)
	fmt.Printf("Message: %s\n", message)
	fmt.Println("Files:")
	sort.Slice(files, func(i, j int) bool { return files[i][0] < files[j][0] })
	for _, f := range files {
		fmt.Printf("  %s %s\n", f[0], f[1])
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: minigit <command>")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "init":
		cmdInit()
	case "add":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit add <file>")
			os.Exit(1)
		}
		cmdAdd(os.Args[2])
	case "commit":
		if len(os.Args) < 4 || os.Args[2] != "-m" {
			fmt.Println("Usage: minigit commit -m \"<message>\"")
			os.Exit(1)
		}
		cmdCommit(os.Args[3])
	case "log":
		cmdLog()
	case "status":
		cmdStatus()
	case "diff":
		if len(os.Args) < 4 {
			fmt.Println("Usage: minigit diff <commit1> <commit2>")
			os.Exit(1)
		}
		cmdDiff(os.Args[2], os.Args[3])
	case "checkout":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit checkout <commit_hash>")
			os.Exit(1)
		}
		cmdCheckout(os.Args[2])
	case "reset":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit reset <commit_hash>")
			os.Exit(1)
		}
		cmdReset(os.Args[2])
	case "rm":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit rm <file>")
			os.Exit(1)
		}
		cmdRm(os.Args[2])
	case "show":
		if len(os.Args) < 3 {
			fmt.Println("Usage: minigit show <commit_hash>")
			os.Exit(1)
		}
		cmdShow(os.Args[2])
	default:
		fmt.Printf("Unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
