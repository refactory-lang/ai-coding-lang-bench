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
    } else if (strcmp(argv[1], "log") == 0) {
        return cmd_log();
    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
        return 1;
    }
}
