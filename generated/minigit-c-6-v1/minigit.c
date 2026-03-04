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
    if (strcmp(argv[1], "log") == 0) return cmd_log();

    fprintf(stderr, "Unknown command: %s\n", argv[1]);
    return 1;
}
