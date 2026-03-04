#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

static void minihash(const unsigned char *data, size_t len, char out[17]) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= data[i];
        h *= 1099511628211ULL;
    }
    snprintf(out, 17, "%016llx", (unsigned long long)h);
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static int is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static void mkdir_p(const char *path) {
    mkdir(path, 0755);
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

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(1); }
    fwrite(data, 1, len, f);
    fclose(f);
}

static int cmd_init(void) {
    if (is_dir(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdir_p(".minigit");
    mkdir_p(".minigit/objects");
    mkdir_p(".minigit/commits");
    write_file(".minigit/index", "", 0);
    write_file(".minigit/HEAD", "", 0);
    return 0;
}

/* Read index lines into array, return count */
static int read_index(char ***lines_out) {
    size_t len;
    char *data = read_file(".minigit/index", &len);
    if (!data || len == 0) {
        free(data);
        *lines_out = NULL;
        return 0;
    }
    /* count lines */
    int count = 0;
    int cap = 64;
    char **lines = malloc(cap * sizeof(char *));
    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen > 0) {
            if (count >= cap) { cap *= 2; lines = realloc(lines, cap * sizeof(char *)); }
            lines[count] = malloc(llen + 1);
            memcpy(lines[count], p, llen);
            lines[count][llen] = '\0';
            count++;
        }
        if (nl) p = nl + 1; else break;
    }
    free(data);
    *lines_out = lines;
    return count;
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

    /* Check if already in index */
    char **lines;
    int count = read_index(&lines);
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) found = 1;
        free(lines[i]);
    }
    free(lines);

    if (!found) {
        FILE *f = fopen(".minigit/index", "a");
        fprintf(f, "%s\n", filename);
        fclose(f);
    }
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    char **lines;
    int count = read_index(&lines);
    if (count == 0) {
        printf("Nothing to commit\n");
        free(lines);
        return 1;
    }

    /* Sort filenames */
    qsort(lines, count, sizeof(char *), cmp_str);

    /* Get parent */
    size_t head_len;
    char *head = read_file(".minigit/HEAD", &head_len);
    char *parent = (head && head_len > 0) ? head : NULL;
    /* trim newline from head */
    if (parent) {
        char *nl = strchr(parent, '\n');
        if (nl) *nl = '\0';
        if (strlen(parent) == 0) parent = NULL;
    }

    /* Build file entries: filename blobhash */
    /* We need to hash each file's current blob */
    char **file_entries = malloc(count * sizeof(char *));
    for (int i = 0; i < count; i++) {
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            /* file might have been removed; use empty hash */
            minihash((unsigned char *)"", 0, fhash);
        }
        file_entries[i] = malloc(strlen(lines[i]) + 1 + 16 + 1);
        sprintf(file_entries[i], "%s %s", lines[i], fhash);
    }

    /* Get timestamp */
    long ts = (long)time(NULL);

    /* Build commit content */
    /* Calculate size */
    size_t content_size = 0;
    content_size += 64; /* parent line */
    content_size += 64; /* timestamp line */
    content_size += strlen(message) + 32; /* message line */
    content_size += 16; /* files: line */
    for (int i = 0; i < count; i++)
        content_size += strlen(file_entries[i]) + 2;

    char *content = malloc(content_size);
    int off = 0;
    off += sprintf(content + off, "parent: %s\n", parent ? parent : "NONE");
    off += sprintf(content + off, "timestamp: %ld\n", ts);
    off += sprintf(content + off, "message: %s\n", message);
    off += sprintf(content + off, "files:\n");
    for (int i = 0; i < count; i++) {
        off += sprintf(content + off, "%s\n", file_entries[i]);
    }

    char commit_hash[17];
    minihash((unsigned char *)content, off, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, off);

    /* Update HEAD */
    char head_content[18];
    snprintf(head_content, sizeof(head_content), "%s", commit_hash);
    write_file(".minigit/HEAD", head_content, strlen(head_content));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    /* Cleanup */
    for (int i = 0; i < count; i++) {
        free(lines[i]);
        free(file_entries[i]);
    }
    free(lines);
    free(file_entries);
    free(content);
    free(head);
    return 0;
}

static int cmd_status(void) {
    char **lines;
    int count = read_index(&lines);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++) {
            printf("%s\n", lines[i]);
            free(lines[i]);
        }
        free(lines);
    }
    return 0;
}

/* Parse commit file, extract files section into parallel arrays */
static int parse_commit_files(const char *cdata, char ***fnames, char ***fhashes) {
    /* Find "files:\n" */
    const char *fp = strstr(cdata, "files:\n");
    if (!fp) { *fnames = NULL; *fhashes = NULL; return 0; }
    fp += 7; /* skip "files:\n" */
    int count = 0, cap = 64;
    char **names = malloc(cap * sizeof(char *));
    char **hashes = malloc(cap * sizeof(char *));
    while (*fp) {
        const char *nl = strchr(fp, '\n');
        size_t llen = nl ? (size_t)(nl - fp) : strlen(fp);
        if (llen == 0) { if (nl) { fp = nl + 1; continue; } else break; }
        /* line is "filename hash" */
        char *line = malloc(llen + 1);
        memcpy(line, fp, llen);
        line[llen] = '\0';
        char *sp = strrchr(line, ' ');
        if (sp) {
            *sp = '\0';
            if (count >= cap) { cap *= 2; names = realloc(names, cap * sizeof(char *)); hashes = realloc(hashes, cap * sizeof(char *)); }
            names[count] = strdup(line);
            hashes[count] = strdup(sp + 1);
            count++;
        }
        free(line);
        if (nl) fp = nl + 1; else break;
    }
    *fnames = names;
    *fhashes = hashes;
    return count;
}

static int cmd_diff(const char *c1, const char *c2) {
    char p1[512], p2[512];
    snprintf(p1, sizeof(p1), ".minigit/commits/%s", c1);
    snprintf(p2, sizeof(p2), ".minigit/commits/%s", c2);
    if (!file_exists(p1) || !file_exists(p2)) {
        printf("Invalid commit\n");
        return 1;
    }
    size_t len1, len2;
    char *d1 = read_file(p1, &len1);
    char *d2 = read_file(p2, &len2);

    char **fn1, **fh1, **fn2, **fh2;
    int cnt1 = parse_commit_files(d1, &fn1, &fh1);
    int cnt2 = parse_commit_files(d2, &fn2, &fh2);

    /* Collect all unique filenames, sorted */
    int allcap = cnt1 + cnt2;
    char **all = malloc(allcap * sizeof(char *));
    int allcnt = 0;
    for (int i = 0; i < cnt1; i++) {
        int dup = 0;
        for (int j = 0; j < allcnt; j++) if (strcmp(all[j], fn1[i]) == 0) { dup = 1; break; }
        if (!dup) all[allcnt++] = fn1[i];
    }
    for (int i = 0; i < cnt2; i++) {
        int dup = 0;
        for (int j = 0; j < allcnt; j++) if (strcmp(all[j], fn2[i]) == 0) { dup = 1; break; }
        if (!dup) all[allcnt++] = fn2[i];
    }
    qsort(all, allcnt, sizeof(char *), cmp_str);

    for (int i = 0; i < allcnt; i++) {
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < cnt1; j++) if (strcmp(fn1[j], all[i]) == 0) { h1 = fh1[j]; break; }
        for (int j = 0; j < cnt2; j++) if (strcmp(fn2[j], all[i]) == 0) { h2 = fh2[j]; break; }
        if (h1 && !h2) printf("Removed: %s\n", all[i]);
        else if (!h1 && h2) printf("Added: %s\n", all[i]);
        else if (h1 && h2 && strcmp(h1, h2) != 0) printf("Modified: %s\n", all[i]);
    }

    for (int i = 0; i < cnt1; i++) { free(fn1[i]); free(fh1[i]); }
    for (int i = 0; i < cnt2; i++) { free(fn2[i]); free(fh2[i]); }
    free(fn1); free(fh1); free(fn2); free(fh2);
    free(all); free(d1); free(d2);
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
    char **fnames, **fhashes;
    int cnt = parse_commit_files(cdata, &fnames, &fhashes);
    for (int i = 0; i < cnt; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", fhashes[i]);
        size_t olen;
        char *odata = read_file(objpath, &olen);
        if (odata) {
            write_file(fnames[i], odata, olen);
            free(odata);
        }
        free(fnames[i]);
        free(fhashes[i]);
    }
    free(fnames); free(fhashes); free(cdata);
    /* Update HEAD */
    write_file(".minigit/HEAD", hash, strlen(hash));
    /* Clear index */
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
    char **lines;
    int count = read_index(&lines);
    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) { found = i; break; }
    }
    if (found < 0) {
        printf("File not in index\n");
        for (int i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 1;
    }
    /* Rewrite index without this file */
    FILE *f = fopen(".minigit/index", "w");
    for (int i = 0; i < count; i++) {
        if (i != found) fprintf(f, "%s\n", lines[i]);
        free(lines[i]);
    }
    fclose(f);
    free(lines);
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

    char *line = cdata;
    while (line && *line) {
        char *next = strchr(line, '\n');
        size_t llen = next ? (size_t)(next - line) : strlen(line);
        char buf[2048];
        if (llen >= sizeof(buf)) llen = sizeof(buf) - 1;
        memcpy(buf, line, llen);
        buf[llen] = '\0';
        if (strncmp(buf, "timestamp: ", 11) == 0)
            strncpy(timestamp, buf + 11, sizeof(timestamp) - 1);
        else if (strncmp(buf, "message: ", 9) == 0)
            strncpy(message, buf + 9, sizeof(message) - 1);
        else if (strcmp(buf, "files:") == 0) {
            if (next) line = next + 1;
            break;
        }
        if (next) line = next + 1; else { line = NULL; break; }
    }

    printf("commit %s\n", hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");

    /* Parse and print files with 2-space indent */
    if (line) {
        char **fnames, **fhashes;
        int cnt = parse_commit_files(cdata, &fnames, &fhashes);
        /* Sort (should already be sorted but just in case) */
        /* Simple bubble sort on parallel arrays */
        for (int i = 0; i < cnt - 1; i++) {
            for (int j = i + 1; j < cnt; j++) {
                if (strcmp(fnames[i], fnames[j]) > 0) {
                    char *t = fnames[i]; fnames[i] = fnames[j]; fnames[j] = t;
                    t = fhashes[i]; fhashes[i] = fhashes[j]; fhashes[j] = t;
                }
            }
        }
        for (int i = 0; i < cnt; i++) {
            printf("  %s %s\n", fnames[i], fhashes[i]);
            free(fnames[i]); free(fhashes[i]);
        }
        free(fnames); free(fhashes);
    }

    free(cdata);
    return 0;
}

static int cmd_log(void) {
    size_t head_len;
    char *head = read_file(".minigit/HEAD", &head_len);
    if (!head || head_len == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }
    /* trim */
    char *nl = strchr(head, '\n');
    if (nl) *nl = '\0';
    if (strlen(head) == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[17];
    strncpy(current, head, 16);
    current[16] = '\0';
    free(head);

    while (1) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        size_t clen;
        char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* Parse parent, timestamp, message */
        char parent[64] = "";
        char timestamp[64] = "";
        char message[1024] = "";

        char *line = cdata;
        while (line && *line) {
            char *next = strchr(line, '\n');
            size_t llen = next ? (size_t)(next - line) : strlen(line);
            char buf[2048];
            if (llen >= sizeof(buf)) llen = sizeof(buf) - 1;
            memcpy(buf, line, llen);
            buf[llen] = '\0';

            if (strncmp(buf, "parent: ", 8) == 0) {
                strncpy(parent, buf + 8, sizeof(parent) - 1);
            } else if (strncmp(buf, "timestamp: ", 11) == 0) {
                strncpy(timestamp, buf + 11, sizeof(timestamp) - 1);
            } else if (strncmp(buf, "message: ", 9) == 0) {
                strncpy(message, buf + 9, sizeof(message) - 1);
            }

            if (next) line = next + 1; else break;
        }

        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        printf("\n");

        free(cdata);

        if (strcmp(parent, "NONE") == 0 || strlen(parent) == 0) break;
        strncpy(current, parent, 16);
        current[16] = '\0';
    }

    return 0;
}

int main(int argc, char *argv[]) {
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
        if (argc < 4) { fprintf(stderr, "Usage: minigit diff <c1> <c2>\n"); return 1; }
        return cmd_diff(argv[2], argv[3]);
    } else if (strcmp(argv[1], "checkout") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit checkout <hash>\n"); return 1; }
        return cmd_checkout(argv[2]);
    } else if (strcmp(argv[1], "reset") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit reset <hash>\n"); return 1; }
        return cmd_reset(argv[2]);
    } else if (strcmp(argv[1], "rm") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit rm <file>\n"); return 1; }
        return cmd_rm(argv[2]);
    } else if (strcmp(argv[1], "show") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit show <hash>\n"); return 1; }
        return cmd_show(argv[2]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
        return 1;
    }
}
