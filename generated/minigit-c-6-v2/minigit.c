#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <time.h>

/* MiniHash: FNV-1a variant, 64-bit, 16-char hex output */
static void minihash(const unsigned char *data, size_t len, char out[17]) {
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
    size_t n = fread(buf, 1, sz, f);
    fclose(f);
    minihash(buf, n, out);
    free(buf);
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

static char *read_file_text(const char *path, size_t *outlen) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    size_t n = fread(buf, 1, sz, f);
    buf[n] = '\0';
    fclose(f);
    if (outlen) *outlen = n;
    return buf;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fwrite(data, 1, len, f);
    fclose(f);
}

/* Read index file, return array of lines (filenames). Count in *cnt. */
static char **read_index(int *cnt) {
    *cnt = 0;
    char *data = read_file_text(".minigit/index", NULL);
    if (!data || data[0] == '\0') { free(data); return NULL; }

    /* count lines */
    int cap = 64;
    char **lines = malloc(cap * sizeof(char *));
    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen > 0) {
            if (*cnt >= cap) { cap *= 2; lines = realloc(lines, cap * sizeof(char *)); }
            lines[*cnt] = strndup(p, llen);
            (*cnt)++;
        }
        if (nl) p = nl + 1; else break;
    }
    free(data);
    return lines;
}

static int cmpstr(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
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

    /* hash and store blob */
    char hash[17];
    minihash_file(filename, hash);

    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);

    if (!file_exists(objpath)) {
        /* copy file content to object */
        size_t len;
        char *content = read_file_text(filename, &len);
        write_file(objpath, content, len);
        free(content);
    }

    /* add to index if not already present */
    int cnt;
    char **lines = read_index(&cnt);
    for (int i = 0; i < cnt; i++) {
        if (strcmp(lines[i], filename) == 0) {
            for (int j = 0; j < cnt; j++) free(lines[j]);
            free(lines);
            return 0;
        }
    }

    /* append */
    FILE *f = fopen(".minigit/index", "a");
    fprintf(f, "%s\n", filename);
    fclose(f);

    for (int i = 0; i < cnt; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_commit(const char *message) {
    int cnt;
    char **files = read_index(&cnt);
    if (cnt == 0) {
        printf("Nothing to commit\n");
        free(files);
        return 1;
    }

    /* sort filenames */
    qsort(files, cnt, sizeof(char *), cmpstr);

    /* read HEAD */
    char *head = read_file_text(".minigit/HEAD", NULL);
    const char *parent = (head && head[0]) ? head : "NONE";

    /* build commit content */
    /* first pass: compute size */
    size_t sz = 0;
    sz += strlen("parent: ") + strlen(parent) + 1;
    char tsbuf[32];
    snprintf(tsbuf, sizeof(tsbuf), "%ld", (long)time(NULL));
    sz += strlen("timestamp: ") + strlen(tsbuf) + 1;
    sz += strlen("message: ") + strlen(message) + 1;
    sz += strlen("files:") + 1;
    for (int i = 0; i < cnt; i++) {
        char hash[17];
        minihash_file(files[i], hash);
        sz += strlen(files[i]) + 1 + 16 + 1;
    }

    char *commit = malloc(sz + 1);
    char *p = commit;
    p += sprintf(p, "parent: %s\n", parent);
    p += sprintf(p, "timestamp: %s\n", tsbuf);
    p += sprintf(p, "message: %s\n", message);
    p += sprintf(p, "files:\n");
    for (int i = 0; i < cnt; i++) {
        char hash[17];
        minihash_file(files[i], hash);
        p += sprintf(p, "%s %s\n", files[i], hash);
    }
    size_t commit_len = p - commit;

    /* hash the commit */
    char commit_hash[17];
    minihash((unsigned char *)commit, commit_len, commit_hash);

    /* write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, commit, commit_len);

    /* update HEAD */
    write_file(".minigit/HEAD", commit_hash, 16);

    /* clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    free(commit);
    free(head);
    for (int i = 0; i < cnt; i++) free(files[i]);
    free(files);
    return 0;
}

static int cmd_status(void) {
    int cnt;
    char **files = read_index(&cnt);
    printf("Staged files:\n");
    if (cnt == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < cnt; i++) {
            printf("%s\n", files[i]);
            free(files[i]);
        }
    }
    free(files);
    return 0;
}

static int cmd_log(void) {
    char *head = read_file_text(".minigit/HEAD", NULL);
    if (!head || head[0] == '\0') {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[17];
    strncpy(current, head, 16);
    current[16] = '\0';
    free(head);

    int first = 1;
    while (current[0]) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        char *data = read_file_text(cpath, NULL);
        if (!data) break;

        /* parse parent, timestamp, message */
        char parent[64] = "";
        char timestamp[64] = "";
        char message[1024] = "";

        char *line = strtok(data, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0)
                strncpy(parent, line + 8, sizeof(parent) - 1);
            else if (strncmp(line, "timestamp: ", 11) == 0)
                strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
            else if (strncmp(line, "message: ", 9) == 0)
                strncpy(message, line + 9, sizeof(message) - 1);
            line = strtok(NULL, "\n");
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        free(data);

        if (strcmp(parent, "NONE") == 0 || parent[0] == '\0')
            break;
        strncpy(current, parent, 16);
        current[16] = '\0';
    }
    return 0;
}

/* Parse commit file: extract files section into parallel arrays of filenames and hashes */
static int parse_commit_files(const char *commit_hash, char ***out_names, char ***out_hashes, int *out_cnt) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    char *data = read_file_text(cpath, NULL);
    if (!data) return -1;

    *out_cnt = 0;
    int cap = 64;
    *out_names = malloc(cap * sizeof(char *));
    *out_hashes = malloc(cap * sizeof(char *));

    /* find "files:" line, then parse subsequent lines */
    int in_files = 0;
    char *saveptr = NULL;
    char *line = strtok_r(data, "\n", &saveptr);
    while (line) {
        if (!in_files) {
            if (strcmp(line, "files:") == 0) in_files = 1;
        } else {
            /* expect "filename hash" */
            char *sp = strchr(line, ' ');
            if (sp) {
                if (*out_cnt >= cap) {
                    cap *= 2;
                    *out_names = realloc(*out_names, cap * sizeof(char *));
                    *out_hashes = realloc(*out_hashes, cap * sizeof(char *));
                }
                (*out_names)[*out_cnt] = strndup(line, sp - line);
                (*out_hashes)[*out_cnt] = strdup(sp + 1);
                (*out_cnt)++;
            }
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }
    free(data);
    return 0;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char **names1, **hashes1, **names2, **hashes2;
    int cnt1, cnt2;

    if (parse_commit_files(hash1, &names1, &hashes1, &cnt1) != 0) {
        printf("Invalid commit\n");
        return 1;
    }
    if (parse_commit_files(hash2, &names2, &hashes2, &cnt2) != 0) {
        printf("Invalid commit\n");
        for (int i = 0; i < cnt1; i++) { free(names1[i]); free(hashes1[i]); }
        free(names1); free(hashes1);
        return 1;
    }

    /* Collect all unique filenames, sorted */
    int allcap = cnt1 + cnt2;
    char **allnames = malloc(allcap * sizeof(char *));
    int allcnt = 0;

    for (int i = 0; i < cnt1; i++) {
        int found = 0;
        for (int j = 0; j < allcnt; j++) {
            if (strcmp(allnames[j], names1[i]) == 0) { found = 1; break; }
        }
        if (!found) allnames[allcnt++] = names1[i];
    }
    for (int i = 0; i < cnt2; i++) {
        int found = 0;
        for (int j = 0; j < allcnt; j++) {
            if (strcmp(allnames[j], names2[i]) == 0) { found = 1; break; }
        }
        if (!found) allnames[allcnt++] = names2[i];
    }
    qsort(allnames, allcnt, sizeof(char *), cmpstr);

    for (int i = 0; i < allcnt; i++) {
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < cnt1; j++) {
            if (strcmp(names1[j], allnames[i]) == 0) { h1 = hashes1[j]; break; }
        }
        for (int j = 0; j < cnt2; j++) {
            if (strcmp(names2[j], allnames[i]) == 0) { h2 = hashes2[j]; break; }
        }
        if (!h1 && h2) printf("Added: %s\n", allnames[i]);
        else if (h1 && !h2) printf("Removed: %s\n", allnames[i]);
        else if (h1 && h2 && strcmp(h1, h2) != 0) printf("Modified: %s\n", allnames[i]);
    }

    free(allnames);
    for (int i = 0; i < cnt1; i++) { free(names1[i]); free(hashes1[i]); }
    free(names1); free(hashes1);
    for (int i = 0; i < cnt2; i++) { free(names2[i]); free(hashes2[i]); }
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
    int cnt;
    parse_commit_files(commit_hash, &names, &hashes, &cnt);

    for (int i = 0; i < cnt; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hashes[i]);
        size_t len;
        char *content = read_file_text(objpath, &len);
        if (content) {
            write_file(names[i], content, len);
            free(content);
        }
        free(names[i]);
        free(hashes[i]);
    }
    free(names);
    free(hashes);

    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));
    write_file(".minigit/index", "", 0);

    printf("Checked out %s\n", commit_hash);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));
    write_file(".minigit/index", "", 0);

    printf("Reset to %s\n", commit_hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    int cnt;
    char **lines = read_index(&cnt);
    int found = -1;
    for (int i = 0; i < cnt; i++) {
        if (strcmp(lines[i], filename) == 0) { found = i; break; }
    }
    if (found < 0) {
        printf("File not in index\n");
        for (int i = 0; i < cnt; i++) free(lines[i]);
        free(lines);
        return 1;
    }

    FILE *f = fopen(".minigit/index", "w");
    for (int i = 0; i < cnt; i++) {
        if (i != found) fprintf(f, "%s\n", lines[i]);
        free(lines[i]);
    }
    fclose(f);
    free(lines);
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    char *data = read_file_text(cpath, NULL);
    if (!data) {
        printf("Invalid commit\n");
        return 1;
    }

    char timestamp[64] = "";
    char message[1024] = "";
    char **fnames = NULL, **fhashes = NULL;
    int fcnt = 0, fcap = 64;
    fnames = malloc(fcap * sizeof(char *));
    fhashes = malloc(fcap * sizeof(char *));

    int in_files = 0;
    char *saveptr = NULL;
    char *line = strtok_r(data, "\n", &saveptr);
    while (line) {
        if (!in_files) {
            if (strncmp(line, "timestamp: ", 11) == 0)
                strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
            else if (strncmp(line, "message: ", 9) == 0)
                strncpy(message, line + 9, sizeof(message) - 1);
            else if (strcmp(line, "files:") == 0)
                in_files = 1;
        } else {
            char *sp = strchr(line, ' ');
            if (sp) {
                if (fcnt >= fcap) { fcap *= 2; fnames = realloc(fnames, fcap * sizeof(char *)); fhashes = realloc(fhashes, fcap * sizeof(char *)); }
                fnames[fcnt] = strndup(line, sp - line);
                fhashes[fcnt] = strdup(sp + 1);
                fcnt++;
            }
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }

    qsort(fnames, fcnt, sizeof(char *), cmpstr);
    /* sort hashes in parallel - need to sort together */
    /* Actually, re-sort using indices */
    /* Simpler: re-parse or sort pairs. Let me sort pairs. */
    /* The files should already be sorted from commit creation, but let's be safe */

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");

    /* Need to sort name-hash pairs together. Rebuild from parsed data. */
    /* Since we already parsed into parallel arrays, let's sort them together */
    /* Simple bubble sort on fnames, swapping fhashes in parallel */
    /* Actually we already sorted fnames but not fhashes. Let me redo. */
    /* Re-read from the parsed data before sorting */
    free(data);

    /* Re-parse to get properly paired data */
    /* Actually, let me just re-parse */
    char **names2, **hashes2;
    int cnt2;
    parse_commit_files(commit_hash, &names2, &hashes2, &cnt2);

    /* Sort pairs by name */
    for (int i = 0; i < cnt2 - 1; i++) {
        for (int j = i + 1; j < cnt2; j++) {
            if (strcmp(names2[i], names2[j]) > 0) {
                char *tmp = names2[i]; names2[i] = names2[j]; names2[j] = tmp;
                tmp = hashes2[i]; hashes2[i] = hashes2[j]; hashes2[j] = tmp;
            }
        }
    }

    for (int i = 0; i < cnt2; i++) {
        printf("  %s %s\n", names2[i], hashes2[i]);
        free(names2[i]); free(hashes2[i]);
    }
    free(names2); free(hashes2);

    for (int i = 0; i < fcnt; i++) { free(fnames[i]); free(fhashes[i]); }
    free(fnames); free(fhashes);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command>\n");
        return 1;
    }

    if (strcmp(argv[1], "init") == 0) return cmd_init();
    if (strcmp(argv[1], "add") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit add <file>\n"); return 1; }
        return cmd_add(argv[2]);
    }
    if (strcmp(argv[1], "commit") == 0) {
        if (argc < 4 || strcmp(argv[2], "-m") != 0) {
            fprintf(stderr, "Usage: minigit commit -m \"<message>\"\n"); return 1;
        }
        return cmd_commit(argv[3]);
    }
    if (strcmp(argv[1], "status") == 0) return cmd_status();
    if (strcmp(argv[1], "log") == 0) return cmd_log();
    if (strcmp(argv[1], "diff") == 0) {
        if (argc < 4) { fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n"); return 1; }
        return cmd_diff(argv[2], argv[3]);
    }
    if (strcmp(argv[1], "checkout") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit checkout <commit_hash>\n"); return 1; }
        return cmd_checkout(argv[2]);
    }
    if (strcmp(argv[1], "reset") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit reset <commit_hash>\n"); return 1; }
        return cmd_reset(argv[2]);
    }
    if (strcmp(argv[1], "rm") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit rm <file>\n"); return 1; }
        return cmd_rm(argv[2]);
    }
    if (strcmp(argv[1], "show") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit show <commit_hash>\n"); return 1; }
        return cmd_show(argv[2]);
    }

    fprintf(stderr, "Unknown command: %s\n", argv[1]);
    return 1;
}
