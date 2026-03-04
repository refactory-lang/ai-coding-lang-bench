#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>

/* MiniHash: FNV-1a variant, 64-bit, 16-char hex output */
static void minihash(const unsigned char *data, size_t len, char out[17]) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= data[i];
        h *= 1099511628211ULL;
    }
    snprintf(out, 17, "%016llx", (unsigned long long)h);
}

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    if (out_len) *out_len = rd;
    fclose(f);
    return buf;
}

static int write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(data, 1, len, f);
    fclose(f);
    return 0;
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static int dir_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static void mkdirp(const char *path) {
    mkdir(path, 0755);
}

/* Read index file, return array of lines. Caller frees each line and the array. */
static char **read_index(int *count) {
    *count = 0;
    size_t len;
    char *data = read_file(".minigit/index", &len);
    if (!data || len == 0) {
        free(data);
        return NULL;
    }

    /* Count lines */
    int cap = 16;
    char **lines = malloc(cap * sizeof(char *));
    int n = 0;

    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen > 0) {
            if (n >= cap) {
                cap *= 2;
                lines = realloc(lines, cap * sizeof(char *));
            }
            lines[n] = malloc(llen + 1);
            memcpy(lines[n], p, llen);
            lines[n][llen] = '\0';
            n++;
        }
        if (nl) p = nl + 1;
        else break;
    }
    free(data);
    *count = n;
    return lines;
}

static void write_index(char **lines, int count) {
    FILE *f = fopen(".minigit/index", "w");
    if (!f) return;
    for (int i = 0; i < count; i++) {
        fprintf(f, "%s\n", lines[i]);
    }
    fclose(f);
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

/* ==================== COMMANDS ==================== */

static int cmd_init(void) {
    if (dir_exists(".minigit")) {
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

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    /* Read file and hash */
    size_t flen;
    char *data = read_file(filename, &flen);
    if (!data) {
        printf("File not found\n");
        return 1;
    }

    char hash[17];
    minihash((unsigned char *)data, flen, hash);

    /* Store blob */
    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, data, flen);
    free(data);

    /* Update index: add filename if not present */
    int count;
    char **lines = read_index(&count);

    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) {
            /* Already in index */
            for (int j = 0; j < count; j++) free(lines[j]);
            free(lines);
            return 0;
        }
    }

    /* Append */
    if (!lines) {
        lines = malloc(sizeof(char *));
    } else {
        lines = realloc(lines, (count + 1) * sizeof(char *));
    }
    lines[count] = strdup(filename);
    count++;
    write_index(lines, count);

    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_commit(const char *message) {
    /* Read index */
    int count;
    char **lines = read_index(&count);
    if (count == 0) {
        printf("Nothing to commit\n");
        if (lines) free(lines);
        return 1;
    }

    /* Sort filenames */
    qsort(lines, count, sizeof(char *), cmp_str);

    /* Read HEAD for parent */
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    char parent[128] = "NONE";
    if (head && hlen > 0) {
        /* Trim whitespace */
        char *p = head;
        while (*p && *p != '\n' && *p != '\r') p++;
        *p = '\0';
        if (strlen(head) > 0) {
            strncpy(parent, head, sizeof(parent) - 1);
            parent[sizeof(parent) - 1] = '\0';
        }
    }
    free(head);

    /* Get timestamp */
    time_t ts = time(NULL);

    /* Build commit content */
    /* First pass: compute size */
    size_t content_size = 0;
    content_size += snprintf(NULL, 0, "parent: %s\n", parent);
    content_size += snprintf(NULL, 0, "timestamp: %lld\n", (long long)ts);
    content_size += snprintf(NULL, 0, "message: %s\n", message);
    content_size += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < count; i++) {
        /* Hash the current file content */
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            /* File might have been removed; read from objects via index.
               For simplicity, we need to find the blob hash.
               We scan objects dir for matching content...
               Actually per spec, we just hash the file. If file is gone, skip?
               But the spec says files are in the working directory when committed.
               Let's just use an empty hash if file is missing. */
            minihash((unsigned char *)"", 0, fhash);
        }
        content_size += snprintf(NULL, 0, "%s %s\n", lines[i], fhash);
    }

    char *content = malloc(content_size + 1);
    char *ptr = content;
    ptr += sprintf(ptr, "parent: %s\n", parent);
    ptr += sprintf(ptr, "timestamp: %lld\n", (long long)ts);
    ptr += sprintf(ptr, "message: %s\n", message);
    ptr += sprintf(ptr, "files:\n");
    for (int i = 0; i < count; i++) {
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            minihash((unsigned char *)"", 0, fhash);
        }
        ptr += sprintf(ptr, "%s %s\n", lines[i], fhash);
    }

    /* Hash commit content */
    size_t clen = ptr - content;
    char commit_hash[17];
    minihash((unsigned char *)content, clen, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, clen);
    free(content);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_log(void) {
    /* Read HEAD */
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    if (!head || hlen == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    /* Trim */
    char *p = head;
    while (*p && *p != '\n' && *p != '\r') p++;
    *p = '\0';

    if (strlen(head) == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[128];
    strncpy(current, head, sizeof(current) - 1);
    current[sizeof(current) - 1] = '\0';
    free(head);

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);

        size_t clen;
        char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* Parse commit */
        char parent[128] = "";
        char timestamp[64] = "";
        char message[1024] = "";

        char *line = strtok(cdata, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0) {
                strncpy(parent, line + 8, sizeof(parent) - 1);
            } else if (strncmp(line, "timestamp: ", 11) == 0) {
                strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
            } else if (strncmp(line, "message: ", 9) == 0) {
                strncpy(message, line + 9, sizeof(message) - 1);
            } else if (strcmp(line, "files:") == 0) {
                break;
            }
            line = strtok(NULL, "\n");
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        free(cdata);

        /* Move to parent */
        if (strlen(parent) == 0 || strcmp(parent, "NONE") == 0) {
            break;
        }
        strncpy(current, parent, sizeof(current) - 1);
        current[sizeof(current) - 1] = '\0';
    }

    return 0;
}

static int cmd_status(void) {
    int count;
    char **lines = read_index(&count);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++) {
            printf("%s\n", lines[i]);
        }
    }
    if (lines) {
        for (int i = 0; i < count; i++) free(lines[i]);
        free(lines);
    }
    return 0;
}

/* Parse a commit file, extracting file entries. Returns count of files.
   filenames[] and hashes[] are allocated arrays the caller must free. */
static int parse_commit_files(const char *commit_hash, char ***out_names, char ***out_hashes) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    size_t clen;
    char *cdata = read_file(cpath, &clen);
    if (!cdata) return -1;

    /* Find "files:\n" */
    char *files_start = strstr(cdata, "files:\n");
    if (!files_start) {
        free(cdata);
        *out_names = NULL;
        *out_hashes = NULL;
        return 0;
    }
    files_start += 7; /* skip "files:\n" */

    int cap = 16, n = 0;
    char **names = malloc(cap * sizeof(char *));
    char **hashes = malloc(cap * sizeof(char *));

    char *line = files_start;
    while (*line) {
        char *nl = strchr(line, '\n');
        size_t llen = nl ? (size_t)(nl - line) : strlen(line);
        if (llen == 0) { if (nl) { line = nl + 1; continue; } else break; }

        /* Parse "filename hash" */
        char *space = memchr(line, ' ', llen);
        if (space) {
            size_t nlen = space - line;
            size_t hlen = llen - nlen - 1;
            if (n >= cap) { cap *= 2; names = realloc(names, cap * sizeof(char *)); hashes = realloc(hashes, cap * sizeof(char *)); }
            names[n] = malloc(nlen + 1);
            memcpy(names[n], line, nlen);
            names[n][nlen] = '\0';
            hashes[n] = malloc(hlen + 1);
            memcpy(hashes[n], space + 1, hlen);
            hashes[n][hlen] = '\0';
            n++;
        }
        if (nl) line = nl + 1; else break;
    }
    free(cdata);
    *out_names = names;
    *out_hashes = hashes;
    return n;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char **names1, **hashes1, **names2, **hashes2;
    int n1 = parse_commit_files(hash1, &names1, &hashes1);
    if (n1 < 0) {
        printf("Invalid commit\n");
        return 1;
    }
    int n2 = parse_commit_files(hash2, &names2, &hashes2);
    if (n2 < 0) {
        printf("Invalid commit\n");
        for (int i = 0; i < n1; i++) { free(names1[i]); free(hashes1[i]); }
        free(names1); free(hashes1);
        return 1;
    }

    /* Collect all unique filenames and sort */
    int cap = n1 + n2, total = 0;
    char **all = malloc(cap * sizeof(char *));
    for (int i = 0; i < n1; i++) {
        int dup = 0;
        for (int j = 0; j < total; j++) { if (strcmp(all[j], names1[i]) == 0) { dup = 1; break; } }
        if (!dup) all[total++] = names1[i];
    }
    for (int i = 0; i < n2; i++) {
        int dup = 0;
        for (int j = 0; j < total; j++) { if (strcmp(all[j], names2[i]) == 0) { dup = 1; break; } }
        if (!dup) all[total++] = names2[i];
    }
    qsort(all, total, sizeof(char *), cmp_str);

    for (int i = 0; i < total; i++) {
        const char *fname = all[i];
        /* Find in commit1 and commit2 */
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < n1; j++) { if (strcmp(names1[j], fname) == 0) { h1 = hashes1[j]; break; } }
        for (int j = 0; j < n2; j++) { if (strcmp(names2[j], fname) == 0) { h2 = hashes2[j]; break; } }

        if (!h1 && h2) printf("Added: %s\n", fname);
        else if (h1 && !h2) printf("Removed: %s\n", fname);
        else if (h1 && h2 && strcmp(h1, h2) != 0) printf("Modified: %s\n", fname);
    }

    free(all);
    for (int i = 0; i < n1; i++) { free(names1[i]); free(hashes1[i]); }
    free(names1); free(hashes1);
    for (int i = 0; i < n2; i++) { free(names2[i]); free(hashes2[i]); }
    free(names2); free(hashes2);
    return 0;
}

static int cmd_checkout(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    char **names, **hashes;
    int n = parse_commit_files(commit_hash, &names, &hashes);
    if (n < 0) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Restore each file from objects */
    for (int i = 0; i < n; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hashes[i]);
        size_t blen;
        char *blob = read_file(objpath, &blen);
        if (blob) {
            write_file(names[i], blob, blen);
            free(blob);
        }
    }

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Checked out %s\n", commit_hash);

    for (int i = 0; i < n; i++) { free(names[i]); free(hashes[i]); }
    free(names); free(hashes);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char cpath[512];
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
    int count;
    char **lines = read_index(&count);

    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) {
            found = i;
            break;
        }
    }

    if (found < 0) {
        printf("File not in index\n");
        if (lines) {
            for (int i = 0; i < count; i++) free(lines[i]);
            free(lines);
        }
        return 1;
    }

    /* Remove entry by shifting */
    free(lines[found]);
    for (int i = found; i < count - 1; i++) {
        lines[i] = lines[i + 1];
    }
    count--;
    write_index(lines, count);

    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    size_t clen;
    char *cdata = read_file(cpath, &clen);
    if (!cdata) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Parse header fields */
    char timestamp[64] = "";
    char message[1024] = "";

    /* We need to parse without destroying data for files section */
    char *datacopy = strdup(cdata);
    char *line = strtok(datacopy, "\n");
    while (line) {
        if (strncmp(line, "timestamp: ", 11) == 0) {
            strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
        } else if (strncmp(line, "message: ", 9) == 0) {
            strncpy(message, line + 9, sizeof(message) - 1);
        } else if (strcmp(line, "files:") == 0) {
            break;
        }
        line = strtok(NULL, "\n");
    }
    free(datacopy);

    /* Get files */
    char **names, **hashes;
    int n = parse_commit_files(commit_hash, &names, &hashes);

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");
    if (n > 0) {
        /* Sort filenames */
        /* Create index array to sort names/hashes together */
        int *idx = malloc(n * sizeof(int));
        for (int i = 0; i < n; i++) idx[i] = i;
        /* Simple insertion sort */
        for (int i = 1; i < n; i++) {
            int key = idx[i];
            int j = i - 1;
            while (j >= 0 && strcmp(names[idx[j]], names[key]) > 0) {
                idx[j + 1] = idx[j];
                j--;
            }
            idx[j + 1] = key;
        }
        for (int i = 0; i < n; i++) {
            printf("  %s %s\n", names[idx[i]], hashes[idx[i]]);
        }
        free(idx);
        for (int i = 0; i < n; i++) { free(names[i]); free(hashes[i]); }
        free(names); free(hashes);
    }

    free(cdata);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command> [args]\n");
        return 1;
    }

    if (strcmp(argv[1], "init") == 0) {
        return cmd_init();
    } else if (strcmp(argv[1], "add") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit add <file>\n");
            return 1;
        }
        return cmd_add(argv[2]);
    } else if (strcmp(argv[1], "commit") == 0) {
        if (argc < 4 || strcmp(argv[2], "-m") != 0) {
            fprintf(stderr, "Usage: minigit commit -m \"<message>\"\n");
            return 1;
        }
        return cmd_commit(argv[3]);
    } else if (strcmp(argv[1], "status") == 0) {
        return cmd_status();
    } else if (strcmp(argv[1], "log") == 0) {
        return cmd_log();
    } else if (strcmp(argv[1], "diff") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n");
            return 1;
        }
        return cmd_diff(argv[2], argv[3]);
    } else if (strcmp(argv[1], "checkout") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit checkout <commit_hash>\n");
            return 1;
        }
        return cmd_checkout(argv[2]);
    } else if (strcmp(argv[1], "reset") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit reset <commit_hash>\n");
            return 1;
        }
        return cmd_reset(argv[2]);
    } else if (strcmp(argv[1], "rm") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit rm <file>\n");
            return 1;
        }
        return cmd_rm(argv[2]);
    } else if (strcmp(argv[1], "show") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit show <commit_hash>\n");
            return 1;
        }
        return cmd_show(argv[2]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
        return 1;
    }
}
