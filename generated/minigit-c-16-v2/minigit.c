#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <errno.h>

#define MAX_PATH 4096
#define MAX_LINE 4096
#define MAX_FILES 1024

/* MiniHash: FNV-1a variant, 64-bit, 16-char hex */
static void minihash_bytes(const unsigned char *data, size_t len, char out[17]) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= data[i];
        h *= 1099511628211ULL;
    }
    snprintf(out, 17, "%016llx", (unsigned long long)h);
}

static void minihash_file(const char *path, char out[17]) {
    FILE *f = fopen(path, "rb");
    if (!f) { out[0] = '\0'; return; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(sz > 0 ? sz : 1);
    size_t rd = fread(buf, 1, sz, f);
    fclose(f);
    minihash_bytes(buf, rd, out);
    free(buf);
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static int is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static void mkdirp(const char *path) {
    mkdir(path, 0755);
}

/* Read entire file into malloc'd buffer, set *len. Returns NULL on failure. */
static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    if (len) *len = rd;
    fclose(f);
    return buf;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fwrite(data, 1, len, f);
    fclose(f);
}

static void copy_file(const char *src, const char *dst) {
    size_t len;
    char *data = read_file(src, &len);
    if (data) {
        write_file(dst, data, len);
        free(data);
    }
}

/* Parse commit file: extract files section into parallel arrays.
   Returns number of files parsed. */
static int parse_commit_files(const char *commit_content,
                               char fnames[][MAX_PATH],
                               char hashes[][17]) {
    int count = 0;
    /* Find "files:\n" */
    const char *p = strstr(commit_content, "files:\n");
    if (!p) return 0;
    p += 7; /* skip "files:\n" */
    while (*p) {
        /* Each line: <filename> <hash>\n */
        const char *eol = strchr(p, '\n');
        if (!eol) eol = p + strlen(p);
        if (eol == p) break;
        /* Find space separating filename and hash */
        const char *sp = NULL;
        for (const char *s = p; s < eol; s++) {
            if (*s == ' ') sp = s;  /* last space before eol */
        }
        if (!sp) break;
        size_t fname_len = sp - p;
        size_t hash_len = eol - sp - 1;
        if (fname_len >= MAX_PATH) fname_len = MAX_PATH - 1;
        if (hash_len >= 17) hash_len = 16;
        memcpy(fnames[count], p, fname_len);
        fnames[count][fname_len] = '\0';
        memcpy(hashes[count], sp + 1, hash_len);
        hashes[count][hash_len] = '\0';
        count++;
        if (count >= MAX_FILES) break;
        p = (*eol) ? eol + 1 : eol;
    }
    return count;
}

/* ---- Commands ---- */

static int cmd_init(void) {
    if (is_dir(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdirp(".minigit");
    mkdirp(".minigit/objects");
    mkdirp(".minigit/commits");
    write_file(".minigit/index", "", 0);
    write_file(".minigit/HEAD", "", 0);
    return 0;
}

/* Read index lines into array. Returns count. */
static int read_index(char lines[][MAX_PATH]) {
    int count = 0;
    FILE *f = fopen(".minigit/index", "r");
    if (!f) return 0;
    char line[MAX_PATH];
    while (fgets(line, sizeof(line), f)) {
        /* strip newline */
        size_t l = strlen(line);
        while (l > 0 && (line[l-1] == '\n' || line[l-1] == '\r')) line[--l] = '\0';
        if (l == 0) continue;
        strcpy(lines[count++], line);
        if (count >= MAX_FILES) break;
    }
    fclose(f);
    return count;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    char hash[17];
    minihash_file(filename, hash);

    /* Store blob */
    char objpath[MAX_PATH];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    if (!file_exists(objpath)) {
        copy_file(filename, objpath);
    }

    /* Check if already in index */
    char lines[MAX_FILES][MAX_PATH];
    int count = read_index(lines);
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) return 0; /* already staged */
    }

    /* Append to index */
    FILE *f = fopen(".minigit/index", "a");
    if (f) {
        fprintf(f, "%s\n", filename);
        fclose(f);
    }
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

static int cmd_commit(const char *message) {
    /* Read index */
    char files[MAX_FILES][MAX_PATH];
    int count = read_index(files);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(files, count, sizeof(files[0]), cmp_str);

    /* Read HEAD for parent */
    size_t headlen;
    char *head = read_file(".minigit/HEAD", &headlen);
    char parent[64] = "NONE";
    if (head) {
        /* strip whitespace */
        while (headlen > 0 && (head[headlen-1] == '\n' || head[headlen-1] == '\r' || head[headlen-1] == ' '))
            head[--headlen] = '\0';
        if (headlen > 0) strcpy(parent, head);
        free(head);
    }

    /* Get timestamp */
    time_t ts = time(NULL);

    /* Build commit content */
    /* First pass: calculate size needed */
    size_t needed = 0;
    needed += snprintf(NULL, 0, "parent: %s\n", parent);
    needed += snprintf(NULL, 0, "timestamp: %lld\n", (long long)ts);
    needed += snprintf(NULL, 0, "message: %s\n", message);
    needed += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < count; i++) {
        char hash[17];
        minihash_file(files[i], hash);
        needed += snprintf(NULL, 0, "%s %s\n", files[i], hash);
    }

    char *content = malloc(needed + 1);
    size_t pos = 0;
    pos += sprintf(content + pos, "parent: %s\n", parent);
    pos += sprintf(content + pos, "timestamp: %lld\n", (long long)ts);
    pos += sprintf(content + pos, "message: %s\n", message);
    pos += sprintf(content + pos, "files:\n");
    for (int i = 0; i < count; i++) {
        char hash[17];
        minihash_file(files[i], hash);
        pos += sprintf(content + pos, "%s %s\n", files[i], hash);
    }

    /* Hash commit content */
    char commit_hash[17];
    minihash_bytes((unsigned char *)content, pos, commit_hash);

    /* Write commit file */
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, pos);
    free(content);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_log(void) {
    size_t headlen;
    char *head = read_file(".minigit/HEAD", &headlen);
    if (!head || headlen == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }
    /* strip whitespace */
    while (headlen > 0 && (head[headlen-1] == '\n' || head[headlen-1] == '\r' || head[headlen-1] == ' '))
        head[--headlen] = '\0';
    if (headlen == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[64];
    strcpy(current, head);
    free(head);

    while (strcmp(current, "NONE") != 0 && strlen(current) > 0) {
        char cpath[MAX_PATH];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);

        char *content = read_file(cpath, NULL);
        if (!content) break;

        /* Parse parent, timestamp, message */
        char parent[64] = "NONE";
        char timestamp[64] = "";
        char message[MAX_LINE] = "";

        char *line = strtok(content, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0) {
                strcpy(parent, line + 8);
            } else if (strncmp(line, "timestamp: ", 11) == 0) {
                strcpy(timestamp, line + 11);
            } else if (strncmp(line, "message: ", 9) == 0) {
                strcpy(message, line + 9);
            }
            line = strtok(NULL, "\n");
        }

        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        printf("\n");

        free(content);
        strcpy(current, parent);
    }

    return 0;
}

static int cmd_status(void) {
    char lines[MAX_FILES][MAX_PATH];
    int count = read_index(lines);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++) {
            printf("%s\n", lines[i]);
        }
    }
    return 0;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char path1[MAX_PATH], path2[MAX_PATH];
    snprintf(path1, sizeof(path1), ".minigit/commits/%s", hash1);
    snprintf(path2, sizeof(path2), ".minigit/commits/%s", hash2);

    if (!file_exists(path1) || !file_exists(path2)) {
        printf("Invalid commit\n");
        return 1;
    }

    char *c1 = read_file(path1, NULL);
    char *c2 = read_file(path2, NULL);

    static char fnames1[MAX_FILES][MAX_PATH], hashes1[MAX_FILES][17];
    static char fnames2[MAX_FILES][MAX_PATH], hashes2[MAX_FILES][17];
    int n1 = parse_commit_files(c1, fnames1, hashes1);
    int n2 = parse_commit_files(c2, fnames2, hashes2);
    free(c1);
    free(c2);

    /* Collect all unique filenames, sorted */
    typedef char fname_t[MAX_PATH];
    fname_t *allfiles = malloc(sizeof(fname_t) * (n1 + n2));
    int total = 0;
    for (int i = 0; i < n1; i++) { strcpy(allfiles[total++], fnames1[i]); }
    for (int i = 0; i < n2; i++) {
        int found = 0;
        for (int j = 0; j < n1; j++) {
            if (strcmp(fnames2[i], fnames1[j]) == 0) { found = 1; break; }
        }
        if (!found) strcpy(allfiles[total++], fnames2[i]);
    }
    qsort(allfiles, total, sizeof(fname_t), cmp_str);

    for (int i = 0; i < total; i++) {
        /* Find in commit1 and commit2 */
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < n1; j++) {
            if (strcmp(allfiles[i], fnames1[j]) == 0) { h1 = hashes1[j]; break; }
        }
        for (int j = 0; j < n2; j++) {
            if (strcmp(allfiles[i], fnames2[j]) == 0) { h2 = hashes2[j]; break; }
        }
        if (h1 && !h2) {
            printf("Removed: %s\n", allfiles[i]);
        } else if (!h1 && h2) {
            printf("Added: %s\n", allfiles[i]);
        } else if (h1 && h2 && strcmp(h1, h2) != 0) {
            printf("Modified: %s\n", allfiles[i]);
        }
    }
    free(allfiles);
    return 0;
}

static int cmd_checkout(const char *commit_hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    char *content = read_file(cpath, NULL);
    char fnames[MAX_FILES][MAX_PATH], hashes[MAX_FILES][17];
    int nfiles = parse_commit_files(content, fnames, hashes);
    free(content);

    /* Restore each file from objects */
    for (int i = 0; i < nfiles; i++) {
        char objpath[MAX_PATH];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hashes[i]);
        size_t len;
        char *data = read_file(objpath, &len);
        if (data) {
            write_file(fnames[i], data, len);
            free(data);
        }
    }

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Checked out %s\n", commit_hash);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Reset to %s\n", commit_hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    char lines[MAX_FILES][MAX_PATH];
    int count = read_index(lines);
    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) { found = i; break; }
    }
    if (found < 0) {
        printf("File not in index\n");
        return 1;
    }
    /* Rewrite index without this file */
    FILE *f = fopen(".minigit/index", "w");
    if (f) {
        for (int i = 0; i < count; i++) {
            if (i != found) fprintf(f, "%s\n", lines[i]);
        }
        fclose(f);
    }
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    char *content = read_file(cpath, NULL);

    /* Parse fields */
    char timestamp[64] = "";
    char message[MAX_LINE] = "";
    char fnames[MAX_FILES][MAX_PATH];
    char hashes[MAX_FILES][17];

    /* Parse timestamp and message from content (before files section) */
    const char *p = content;
    while (*p) {
        const char *eol = strchr(p, '\n');
        if (!eol) eol = p + strlen(p);
        if (strncmp(p, "timestamp: ", 11) == 0) {
            size_t len = eol - p - 11;
            if (len >= sizeof(timestamp)) len = sizeof(timestamp) - 1;
            memcpy(timestamp, p + 11, len);
            timestamp[len] = '\0';
        } else if (strncmp(p, "message: ", 9) == 0) {
            size_t len = eol - p - 9;
            if (len >= sizeof(message)) len = sizeof(message) - 1;
            memcpy(message, p + 9, len);
            message[len] = '\0';
        } else if (strncmp(p, "files:", 6) == 0) {
            break;
        }
        p = (*eol) ? eol + 1 : eol;
    }

    int nfiles = parse_commit_files(content, fnames, hashes);
    free(content);

    /* Sort files */
    /* They should already be sorted from commit, but sort anyway */
    /* Need to sort fnames and hashes together */
    for (int i = 0; i < nfiles - 1; i++) {
        for (int j = i + 1; j < nfiles; j++) {
            if (strcmp(fnames[i], fnames[j]) > 0) {
                char tmp[MAX_PATH];
                strcpy(tmp, fnames[i]); strcpy(fnames[i], fnames[j]); strcpy(fnames[j], tmp);
                char th[17];
                strcpy(th, hashes[i]); strcpy(hashes[i], hashes[j]); strcpy(hashes[j], th);
            }
        }
    }

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");
    for (int i = 0; i < nfiles; i++) {
        printf("  %s %s\n", fnames[i], hashes[i]);
    }

    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command> [args]\n");
        return 1;
    }

    const char *cmd = argv[1];

    if (strcmp(cmd, "init") == 0) {
        return cmd_init();
    } else if (strcmp(cmd, "add") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit add <file>\n");
            return 1;
        }
        return cmd_add(argv[2]);
    } else if (strcmp(cmd, "commit") == 0) {
        if (argc < 4 || strcmp(argv[2], "-m") != 0) {
            fprintf(stderr, "Usage: minigit commit -m \"<message>\"\n");
            return 1;
        }
        return cmd_commit(argv[3]);
    } else if (strcmp(cmd, "status") == 0) {
        return cmd_status();
    } else if (strcmp(cmd, "log") == 0) {
        return cmd_log();
    } else if (strcmp(cmd, "diff") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n");
            return 1;
        }
        return cmd_diff(argv[2], argv[3]);
    } else if (strcmp(cmd, "checkout") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit checkout <commit_hash>\n");
            return 1;
        }
        return cmd_checkout(argv[2]);
    } else if (strcmp(cmd, "reset") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit reset <commit_hash>\n");
            return 1;
        }
        return cmd_reset(argv[2]);
    } else if (strcmp(cmd, "rm") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit rm <file>\n");
            return 1;
        }
        return cmd_rm(argv[2]);
    } else if (strcmp(cmd, "show") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit show <commit_hash>\n");
            return 1;
        }
        return cmd_show(argv[2]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
}
