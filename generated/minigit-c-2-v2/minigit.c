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

/* Parse commit file: extract parent, timestamp, message, and files */
typedef struct {
    char parent[64];
    char timestamp[64];
    char message[MAX_LINE];
    char filenames[MAX_FILES][256];
    char hashes[MAX_FILES][17];
    int nfiles;
} CommitInfo;

static int parse_commit(const char *data, CommitInfo *info) {
    memset(info, 0, sizeof(*info));
    char *tmp = strdup(data);
    char *saveptr = NULL;
    int in_files = 0;
    char *ln = strtok_r(tmp, "\n", &saveptr);
    while (ln) {
        if (strncmp(ln, "parent: ", 8) == 0) {
            strncpy(info->parent, ln + 8, sizeof(info->parent) - 1);
        } else if (strncmp(ln, "timestamp: ", 11) == 0) {
            strncpy(info->timestamp, ln + 11, sizeof(info->timestamp) - 1);
        } else if (strncmp(ln, "message: ", 9) == 0) {
            strncpy(info->message, ln + 9, sizeof(info->message) - 1);
        } else if (strcmp(ln, "files:") == 0) {
            in_files = 1;
        } else if (in_files && info->nfiles < MAX_FILES) {
            /* Parse "filename hash" */
            char *sp = strchr(ln, ' ');
            if (sp) {
                size_t namelen = sp - ln;
                if (namelen >= 256) namelen = 255;
                strncpy(info->filenames[info->nfiles], ln, namelen);
                info->filenames[info->nfiles][namelen] = '\0';
                strncpy(info->hashes[info->nfiles], sp + 1, 16);
                info->hashes[info->nfiles][16] = '\0';
                info->nfiles++;
            }
        }
        ln = strtok_r(NULL, "\n", &saveptr);
    }
    free(tmp);
    return 0;
}

/* ---- Commands ---- */

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

    /* Hash the file */
    size_t len;
    char *data = read_file(filename, &len);
    if (!data) { fprintf(stderr, "Error reading file\n"); return 1; }

    char hash[17];
    minihash((unsigned char *)data, len, hash);

    /* Store blob */
    char objpath[MAX_PATH];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, data, len);
    free(data);

    /* Update index: append filename if not already present */
    size_t idx_len;
    char *index = read_file(".minigit/index", &idx_len);
    if (!index) { index = strdup(""); idx_len = 0; }

    /* Check if already in index */
    int found = 0;
    char *tmp = strdup(index);
    char *line = strtok(tmp, "\n");
    while (line) {
        if (strcmp(line, filename) == 0) { found = 1; break; }
        line = strtok(NULL, "\n");
    }
    free(tmp);

    if (!found) {
        FILE *f = fopen(".minigit/index", "a");
        if (f) {
            if (idx_len > 0 && index[idx_len - 1] != '\n')
                fprintf(f, "\n");
            fprintf(f, "%s\n", filename);
            fclose(f);
        }
    }
    free(index);
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    /* Read index */
    size_t idx_len;
    char *index = read_file(".minigit/index", &idx_len);
    if (!index || idx_len == 0) {
        free(index);
        printf("Nothing to commit\n");
        return 1;
    }

    /* Parse filenames from index */
    char *files[MAX_FILES];
    int nfiles = 0;
    char *tmp = strdup(index);
    char *line = strtok(tmp, "\n");
    while (line && nfiles < MAX_FILES) {
        if (strlen(line) > 0) {
            files[nfiles++] = strdup(line);
        }
        line = strtok(NULL, "\n");
    }
    free(tmp);
    free(index);

    if (nfiles == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(files, nfiles, sizeof(char *), cmp_str);

    /* Read HEAD for parent */
    size_t head_len;
    char *head = read_file(".minigit/HEAD", &head_len);
    const char *parent = (head && head_len > 0) ? head : "NONE";

    /* Get timestamp */
    time_t now = time(NULL);

    /* Build commit content */
    /* First pass: compute size */
    size_t content_size = 0;
    content_size += snprintf(NULL, 0, "parent: %s\n", parent);
    content_size += snprintf(NULL, 0, "timestamp: %ld\n", (long)now);
    content_size += snprintf(NULL, 0, "message: %s\n", message);
    content_size += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < nfiles; i++) {
        /* Hash the file content for each file */
        size_t flen;
        char *fdata = read_file(files[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            /* File might have been deleted; use stored blob hash from objects */
            /* Try to find by scanning objects - but simpler: re-read from objects */
            strcpy(fhash, "0000000000000000");
        }
        content_size += snprintf(NULL, 0, "%s %s\n", files[i], fhash);
    }

    char *content = malloc(content_size + 1);
    char *p = content;
    p += sprintf(p, "parent: %s\n", parent);
    p += sprintf(p, "timestamp: %ld\n", (long)now);
    p += sprintf(p, "message: %s\n", message);
    p += sprintf(p, "files:\n");
    for (int i = 0; i < nfiles; i++) {
        size_t flen;
        char *fdata = read_file(files[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            strcpy(fhash, "0000000000000000");
        }
        p += sprintf(p, "%s %s\n", files[i], fhash);
    }

    size_t content_len = p - content;

    /* Hash the commit content */
    char commit_hash[17];
    minihash((unsigned char *)content, content_len, commit_hash);

    /* Write commit file */
    char commit_path[MAX_PATH];
    snprintf(commit_path, sizeof(commit_path), ".minigit/commits/%s", commit_hash);
    write_file(commit_path, content, content_len);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    /* Cleanup */
    free(content);
    free(head);
    for (int i = 0; i < nfiles; i++) free(files[i]);

    return 0;
}

static int cmd_log(void) {
    size_t head_len;
    char *head = read_file(".minigit/HEAD", &head_len);
    if (!head || head_len == 0) {
        free(head);
        printf("No commits\n");
        return 0;
    }

    char current[17];
    strncpy(current, head, 16);
    current[16] = '\0';
    free(head);

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char commit_path[MAX_PATH];
        snprintf(commit_path, sizeof(commit_path), ".minigit/commits/%s", current);

        size_t clen;
        char *cdata = read_file(commit_path, &clen);
        if (!cdata) break;

        /* Parse commit */
        char parent[64] = "";
        char timestamp[64] = "";
        char message[MAX_LINE] = "";

        char *tmp = strdup(cdata);
        char *saveptr = NULL;
        char *ln = strtok_r(tmp, "\n", &saveptr);
        while (ln) {
            if (strncmp(ln, "parent: ", 8) == 0) {
                strncpy(parent, ln + 8, sizeof(parent) - 1);
            } else if (strncmp(ln, "timestamp: ", 11) == 0) {
                strncpy(timestamp, ln + 11, sizeof(timestamp) - 1);
            } else if (strncmp(ln, "message: ", 9) == 0) {
                strncpy(message, ln + 9, sizeof(message) - 1);
            }
            ln = strtok_r(NULL, "\n", &saveptr);
        }
        free(tmp);
        free(cdata);

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        /* Move to parent */
        if (strlen(parent) > 0 && strcmp(parent, "NONE") != 0) {
            strncpy(current, parent, 16);
            current[16] = '\0';
        } else {
            break;
        }
    }

    return 0;
}

static int cmd_status(void) {
    size_t idx_len;
    char *index = read_file(".minigit/index", &idx_len);
    printf("Staged files:\n");
    if (!index || idx_len == 0) {
        printf("(none)\n");
        free(index);
        return 0;
    }
    /* Print each filename */
    char *tmp = strdup(index);
    char *saveptr = NULL;
    char *ln = strtok_r(tmp, "\n", &saveptr);
    int found = 0;
    while (ln) {
        if (strlen(ln) > 0) {
            printf("%s\n", ln);
            found = 1;
        }
        ln = strtok_r(NULL, "\n", &saveptr);
    }
    free(tmp);
    free(index);
    if (!found) printf("(none)\n");
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

    size_t len1, len2;
    char *data1 = read_file(path1, &len1);
    char *data2 = read_file(path2, &len2);

    CommitInfo c1, c2;
    parse_commit(data1, &c1);
    parse_commit(data2, &c2);
    free(data1);
    free(data2);

    /* Collect all filenames */
    char *allfiles[MAX_FILES * 2];
    int nall = 0;

    for (int i = 0; i < c1.nfiles; i++) {
        allfiles[nall++] = c1.filenames[i];
    }
    for (int i = 0; i < c2.nfiles; i++) {
        int dup = 0;
        for (int j = 0; j < c1.nfiles; j++) {
            if (strcmp(c2.filenames[i], c1.filenames[j]) == 0) { dup = 1; break; }
        }
        if (!dup) allfiles[nall++] = c2.filenames[i];
    }

    /* Sort */
    qsort(allfiles, nall, sizeof(char *), cmp_str);

    for (int i = 0; i < nall; i++) {
        const char *fname = allfiles[i];
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < c1.nfiles; j++) {
            if (strcmp(c1.filenames[j], fname) == 0) { h1 = c1.hashes[j]; break; }
        }
        for (int j = 0; j < c2.nfiles; j++) {
            if (strcmp(c2.filenames[j], fname) == 0) { h2 = c2.hashes[j]; break; }
        }

        if (!h1 && h2) {
            printf("Added: %s\n", fname);
        } else if (h1 && !h2) {
            printf("Removed: %s\n", fname);
        } else if (h1 && h2 && strcmp(h1, h2) != 0) {
            printf("Modified: %s\n", fname);
        }
    }

    return 0;
}

static int cmd_checkout(const char *hash) {
    char commit_path[MAX_PATH];
    snprintf(commit_path, sizeof(commit_path), ".minigit/commits/%s", hash);

    if (!file_exists(commit_path)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t clen;
    char *cdata = read_file(commit_path, &clen);
    CommitInfo info;
    parse_commit(cdata, &info);
    free(cdata);

    /* Restore each file */
    for (int i = 0; i < info.nfiles; i++) {
        char objpath[MAX_PATH];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", info.hashes[i]);
        size_t blen;
        char *blob = read_file(objpath, &blen);
        if (blob) {
            write_file(info.filenames[i], blob, blen);
            free(blob);
        }
    }

    /* Update HEAD */
    write_file(".minigit/HEAD", hash, strlen(hash));
    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Checked out %s\n", hash);
    return 0;
}

static int cmd_reset(const char *hash) {
    char commit_path[MAX_PATH];
    snprintf(commit_path, sizeof(commit_path), ".minigit/commits/%s", hash);

    if (!file_exists(commit_path)) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Update HEAD */
    write_file(".minigit/HEAD", hash, strlen(hash));
    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Reset to %s\n", hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    size_t idx_len;
    char *index = read_file(".minigit/index", &idx_len);
    if (!index || idx_len == 0) {
        free(index);
        printf("File not in index\n");
        return 1;
    }

    /* Check if file is in index and rebuild without it */
    char *lines[MAX_FILES];
    int nlines = 0;
    int found = 0;
    char *tmp = strdup(index);
    char *saveptr = NULL;
    char *ln = strtok_r(tmp, "\n", &saveptr);
    while (ln && nlines < MAX_FILES) {
        if (strlen(ln) > 0) {
            if (strcmp(ln, filename) == 0) {
                found = 1;
            } else {
                lines[nlines++] = strdup(ln);
            }
        }
        ln = strtok_r(NULL, "\n", &saveptr);
    }
    free(tmp);
    free(index);

    if (!found) {
        for (int i = 0; i < nlines; i++) free(lines[i]);
        printf("File not in index\n");
        return 1;
    }

    /* Rewrite index */
    FILE *f = fopen(".minigit/index", "w");
    if (f) {
        for (int i = 0; i < nlines; i++) {
            fprintf(f, "%s\n", lines[i]);
            free(lines[i]);
        }
        fclose(f);
    }

    return 0;
}

static int cmd_show(const char *hash) {
    char commit_path[MAX_PATH];
    snprintf(commit_path, sizeof(commit_path), ".minigit/commits/%s", hash);

    if (!file_exists(commit_path)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t clen;
    char *cdata = read_file(commit_path, &clen);
    CommitInfo info;
    parse_commit(cdata, &info);
    free(cdata);

    printf("commit %s\n", hash);
    printf("Date: %s\n", info.timestamp);
    printf("Message: %s\n", info.message);
    printf("Files:\n");
    for (int i = 0; i < info.nfiles; i++) {
        printf("  %s %s\n", info.filenames[i], info.hashes[i]);
    }

    return 0;
}

int main(int argc, char *argv[]) {
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
