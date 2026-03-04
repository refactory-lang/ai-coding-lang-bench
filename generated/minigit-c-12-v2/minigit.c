#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>

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

/* ---- commands ---- */

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
    size_t len;
    char *data = read_file(filename, &len);
    char hash[17];
    minihash((unsigned char *)data, len, hash);

    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    if (!file_exists(objpath)) {
        write_file(objpath, data, len);
    }
    free(data);

    /* add to index if not already present */
    size_t idx_len;
    char *idx = read_file(".minigit/index", &idx_len);
    int found = 0;
    if (idx && idx_len > 0) {
        char *line = strtok(idx, "\n");
        while (line) {
            if (strcmp(line, filename) == 0) { found = 1; break; }
            line = strtok(NULL, "\n");
        }
    }
    free(idx);

    if (!found) {
        FILE *f = fopen(".minigit/index", "a");
        fprintf(f, "%s\n", filename);
        fclose(f);
    }
    return 0;
}

/* comparison for qsort of strings */
static int cmpstr(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    size_t idx_len;
    char *idx = read_file(".minigit/index", &idx_len);
    if (!idx || idx_len == 0) {
        free(idx);
        printf("Nothing to commit\n");
        return 1;
    }

    /* parse index lines */
    char *files[4096];
    int nfiles = 0;
    char *idx_copy = strdup(idx);
    char *line = strtok(idx_copy, "\n");
    while (line) {
        if (strlen(line) > 0) files[nfiles++] = strdup(line);
        line = strtok(NULL, "\n");
    }
    free(idx_copy);
    free(idx);

    if (nfiles == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* sort filenames */
    qsort(files, nfiles, sizeof(char *), cmpstr);

    /* get parent */
    size_t head_len;
    char *head = read_file(".minigit/HEAD", &head_len);
    const char *parent = (head && head_len > 0) ? head : "NONE";

    /* get timestamp */
    char ts[64];
    snprintf(ts, sizeof(ts), "%ld", (long)time(NULL));

    /* build commit content */
    /* first compute hashes for each file */
    char *hashes[4096];
    for (int i = 0; i < nfiles; i++) {
        size_t flen;
        char *fdata = read_file(files[i], &flen);
        char h[17];
        minihash((unsigned char *)fdata, flen, h);
        hashes[i] = strdup(h);
        free(fdata);
    }

    /* build content string */
    size_t cap = 4096;
    char *content = malloc(cap);
    size_t pos = 0;

    pos += snprintf(content + pos, cap - pos, "parent: %s\n", parent);
    pos += snprintf(content + pos, cap - pos, "timestamp: %s\n", ts);
    pos += snprintf(content + pos, cap - pos, "message: %s\n", message);
    pos += snprintf(content + pos, cap - pos, "files:\n");
    for (int i = 0; i < nfiles; i++) {
        pos += snprintf(content + pos, cap - pos, "%s %s\n", files[i], hashes[i]);
    }

    /* hash the commit */
    char commit_hash[17];
    minihash((unsigned char *)content, pos, commit_hash);

    /* write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, pos);

    /* update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    /* cleanup */
    for (int i = 0; i < nfiles; i++) {
        free(files[i]);
        free(hashes[i]);
    }
    free(head);
    free(content);

    return 0;
}

static int cmd_status(void) {
    size_t idx_len;
    char *idx = read_file(".minigit/index", &idx_len);
    printf("Staged files:\n");
    if (!idx || idx_len == 0) {
        printf("(none)\n");
        free(idx);
        return 0;
    }
    /* print each line */
    char *line = strtok(idx, "\n");
    int found = 0;
    while (line) {
        if (strlen(line) > 0) {
            printf("%s\n", line);
            found = 1;
        }
        line = strtok(NULL, "\n");
    }
    if (!found) printf("(none)\n");
    free(idx);
    return 0;
}

/* Parse files section from commit data. Returns number of files parsed. */
static int parse_commit_files(const char *cdata, char filenames[][256], char hashes[][17]) {
    int nfiles = 0;
    int in_files = 0;
    char *copy = strdup(cdata);
    char *ln = strtok(copy, "\n");
    while (ln) {
        if (in_files) {
            char fname[256];
            char fhash[17];
            if (sscanf(ln, "%255s %16s", fname, fhash) == 2) {
                strcpy(filenames[nfiles], fname);
                strcpy(hashes[nfiles], fhash);
                nfiles++;
            }
        } else if (strncmp(ln, "files:", 6) == 0) {
            in_files = 1;
        }
        ln = strtok(NULL, "\n");
    }
    free(copy);
    return nfiles;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char path1[512], path2[512];
    snprintf(path1, sizeof(path1), ".minigit/commits/%s", hash1);
    snprintf(path2, sizeof(path2), ".minigit/commits/%s", hash2);

    if (!file_exists(path1) || !file_exists(path2)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t len1, len2;
    char *data1 = read_file(path1, &len1);
    char *data2 = read_file(path2, &len2);

    char fnames1[4096][256], hashes1[4096][17];
    char fnames2[4096][256], hashes2[4096][17];
    int n1 = parse_commit_files(data1, fnames1, hashes1);
    int n2 = parse_commit_files(data2, fnames2, hashes2);
    free(data1);
    free(data2);

    /* Collect all unique filenames, sorted */
    char all[8192][256];
    int nall = 0;
    for (int i = 0; i < n1; i++) {
        int dup = 0;
        for (int j = 0; j < nall; j++) if (strcmp(all[j], fnames1[i]) == 0) { dup = 1; break; }
        if (!dup) strcpy(all[nall++], fnames1[i]);
    }
    for (int i = 0; i < n2; i++) {
        int dup = 0;
        for (int j = 0; j < nall; j++) if (strcmp(all[j], fnames2[i]) == 0) { dup = 1; break; }
        if (!dup) strcpy(all[nall++], fnames2[i]);
    }
    /* sort */
    for (int i = 0; i < nall - 1; i++)
        for (int j = i + 1; j < nall; j++)
            if (strcmp(all[i], all[j]) > 0) {
                char tmp[256];
                strcpy(tmp, all[i]); strcpy(all[i], all[j]); strcpy(all[j], tmp);
            }

    for (int i = 0; i < nall; i++) {
        char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < n1; j++) if (strcmp(fnames1[j], all[i]) == 0) { h1 = hashes1[j]; break; }
        for (int j = 0; j < n2; j++) if (strcmp(fnames2[j], all[i]) == 0) { h2 = hashes2[j]; break; }

        if (!h1 && h2) printf("Added: %s\n", all[i]);
        else if (h1 && !h2) printf("Removed: %s\n", all[i]);
        else if (h1 && h2 && strcmp(h1, h2) != 0) printf("Modified: %s\n", all[i]);
    }

    return 0;
}

static int cmd_checkout(const char *hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t clen;
    char *cdata = read_file(cpath, &clen);

    char fnames[4096][256], fhashes[4096][17];
    int nfiles = parse_commit_files(cdata, fnames, fhashes);
    free(cdata);

    for (int i = 0; i < nfiles; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", fhashes[i]);
        size_t olen;
        char *odata = read_file(objpath, &olen);
        if (odata) {
            write_file(fnames[i], odata, olen);
            free(odata);
        }
    }

    write_file(".minigit/HEAD", hash, strlen(hash));
    write_file(".minigit/index", "", 0);

    printf("Checked out %s\n", hash);
    return 0;
}

static int cmd_reset(const char *hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    write_file(".minigit/HEAD", hash, strlen(hash));
    write_file(".minigit/index", "", 0);

    printf("Reset to %s\n", hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    size_t idx_len;
    char *idx = read_file(".minigit/index", &idx_len);
    if (!idx || idx_len == 0) {
        free(idx);
        printf("File not in index\n");
        return 1;
    }

    /* Check if file is in index and rebuild without it */
    char *lines[4096];
    int nlines = 0;
    int found = 0;
    char *copy = strdup(idx);
    char *ln = strtok(copy, "\n");
    while (ln) {
        if (strlen(ln) > 0) {
            if (strcmp(ln, filename) == 0) {
                found = 1;
            } else {
                lines[nlines++] = strdup(ln);
            }
        }
        ln = strtok(NULL, "\n");
    }
    free(copy);
    free(idx);

    if (!found) {
        for (int i = 0; i < nlines; i++) free(lines[i]);
        printf("File not in index\n");
        return 1;
    }

    /* Rewrite index */
    FILE *f = fopen(".minigit/index", "w");
    for (int i = 0; i < nlines; i++) {
        fprintf(f, "%s\n", lines[i]);
        free(lines[i]);
    }
    fclose(f);

    return 0;
}

static int cmd_show(const char *hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t clen;
    char *cdata = read_file(cpath, &clen);

    char timestamp[64] = "";
    char message[1024] = "";
    char fnames[4096][256], fhashes[4096][17];
    int nfiles = 0;
    int in_files = 0;

    char *copy = strdup(cdata);
    char *ln = strtok(copy, "\n");
    while (ln) {
        if (in_files) {
            char fname[256], fhash[17];
            if (sscanf(ln, "%255s %16s", fname, fhash) == 2) {
                strcpy(fnames[nfiles], fname);
                strcpy(fhashes[nfiles], fhash);
                nfiles++;
            }
        } else if (strncmp(ln, "timestamp: ", 11) == 0) {
            strncpy(timestamp, ln + 11, sizeof(timestamp) - 1);
        } else if (strncmp(ln, "message: ", 9) == 0) {
            strncpy(message, ln + 9, sizeof(message) - 1);
        } else if (strncmp(ln, "files:", 6) == 0) {
            in_files = 1;
        }
        ln = strtok(NULL, "\n");
    }
    free(copy);
    free(cdata);

    printf("commit %s\n", hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");
    for (int i = 0; i < nfiles; i++) {
        printf("  %s %s\n", fnames[i], fhashes[i]);
    }

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

    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        size_t clen;
        char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* parse parent, timestamp, message */
        char parent[64] = "";
        char timestamp[64] = "";
        char message[1024] = "";

        char *copy = strdup(cdata);
        char *ln = strtok(copy, "\n");
        while (ln) {
            if (strncmp(ln, "parent: ", 8) == 0) {
                strncpy(parent, ln + 8, sizeof(parent) - 1);
            } else if (strncmp(ln, "timestamp: ", 11) == 0) {
                strncpy(timestamp, ln + 11, sizeof(timestamp) - 1);
            } else if (strncmp(ln, "message: ", 9) == 0) {
                strncpy(message, ln + 9, sizeof(message) - 1);
            }
            ln = strtok(NULL, "\n");
        }
        free(copy);
        free(cdata);

        printf("commit %s\nDate: %s\nMessage: %s\n\n", current, timestamp, message);

        if (strcmp(parent, "NONE") == 0 || strlen(parent) == 0) break;
        strncpy(current, parent, 16);
        current[16] = '\0';
    }

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
        if (argc < 3) { fprintf(stderr, "Usage: minigit add <file>\n"); return 1; }
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
        if (argc < 4) { fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n"); return 1; }
        return cmd_diff(argv[2], argv[3]);
    } else if (strcmp(argv[1], "checkout") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit checkout <commit_hash>\n"); return 1; }
        return cmd_checkout(argv[2]);
    } else if (strcmp(argv[1], "reset") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit reset <commit_hash>\n"); return 1; }
        return cmd_reset(argv[2]);
    } else if (strcmp(argv[1], "rm") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit rm <file>\n"); return 1; }
        return cmd_rm(argv[2]);
    } else if (strcmp(argv[1], "show") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit show <commit_hash>\n"); return 1; }
        return cmd_show(argv[2]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
        return 1;
    }
}
