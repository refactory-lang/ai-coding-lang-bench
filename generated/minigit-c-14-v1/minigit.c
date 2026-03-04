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

static int dir_exists(const char *path) {
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
    if (dir_exists(".minigit")) {
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

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    /* Hash the file content */
    size_t flen;
    char *content = read_file(filename, &flen);
    if (!content) { printf("File not found\n"); return 1; }

    char hash[17];
    minihash((unsigned char *)content, flen, hash);

    /* Store blob */
    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, content, flen);
    free(content);

    /* Update index: append if not already present */
    size_t ilen;
    char *index = read_file(".minigit/index", &ilen);
    if (!index) { index = strdup(""); ilen = 0; }

    /* Check if filename already in index */
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
        if (ilen > 0 && index[ilen-1] != '\n')
            fprintf(f, "\n");
        fprintf(f, "%s\n", filename);
        fclose(f);
    }
    free(index);
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    /* Read index */
    size_t ilen;
    char *index = read_file(".minigit/index", &ilen);
    if (!index || ilen == 0) {
        printf("Nothing to commit\n");
        free(index);
        return 1;
    }

    /* Parse filenames from index */
    char *filenames[4096];
    int nfiles = 0;
    char *tmp = strdup(index);
    char *line = strtok(tmp, "\n");
    while (line) {
        if (strlen(line) > 0)
            filenames[nfiles++] = strdup(line);
        line = strtok(NULL, "\n");
    }
    free(tmp);

    if (nfiles == 0) {
        printf("Nothing to commit\n");
        free(index);
        return 1;
    }

    /* Sort filenames */
    qsort(filenames, nfiles, sizeof(char *), cmp_str);

    /* Read HEAD */
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    char parent[64] = "NONE";
    if (head && hlen > 0) {
        /* Trim whitespace */
        char *p = head;
        while (*p && *p != '\n' && *p != '\r') p++;
        *p = '\0';
        if (strlen(head) > 0)
            strncpy(parent, head, sizeof(parent) - 1);
    }
    free(head);

    /* Build commit content */
    char commit_buf[65536];
    int off = 0;
    off += snprintf(commit_buf + off, sizeof(commit_buf) - off, "parent: %s\n", parent);
    off += snprintf(commit_buf + off, sizeof(commit_buf) - off, "timestamp: %ld\n", (long)time(NULL));
    off += snprintf(commit_buf + off, sizeof(commit_buf) - off, "message: %s\n", message);
    off += snprintf(commit_buf + off, sizeof(commit_buf) - off, "files:\n");

    for (int i = 0; i < nfiles; i++) {
        /* Hash the file content */
        size_t flen;
        char *content = read_file(filenames[i], &flen);
        char hash[17];
        if (content) {
            minihash((unsigned char *)content, flen, hash);
            free(content);
        } else {
            /* File might have been deleted; try to find it from objects via index */
            hash[0] = '\0';
        }
        off += snprintf(commit_buf + off, sizeof(commit_buf) - off, "%s %s\n", filenames[i], hash);
    }

    /* Hash commit */
    char commit_hash[17];
    minihash((unsigned char *)commit_buf, off, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, commit_buf, off);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    for (int i = 0; i < nfiles; i++) free(filenames[i]);
    free(index);
    return 0;
}

static int cmd_log(void) {
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    if (!head || hlen == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[64];
    strncpy(current, head, sizeof(current) - 1);
    current[sizeof(current) - 1] = '\0';
    /* Trim */
    char *p = current;
    while (*p && *p != '\n' && *p != '\r') p++;
    *p = '\0';
    free(head);

    if (strlen(current) == 0) {
        printf("No commits\n");
        return 0;
    }

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);

        size_t clen;
        char *content = read_file(cpath, &clen);
        if (!content) break;

        /* Parse parent, timestamp, message */
        char par[64] = "NONE";
        char ts[64] = "";
        char msg[4096] = "";

        char *lines = strdup(content);
        char *saveptr;
        char *ln = strtok_r(lines, "\n", &saveptr);
        while (ln) {
            if (strncmp(ln, "parent: ", 8) == 0)
                strncpy(par, ln + 8, sizeof(par) - 1);
            else if (strncmp(ln, "timestamp: ", 11) == 0)
                strncpy(ts, ln + 11, sizeof(ts) - 1);
            else if (strncmp(ln, "message: ", 9) == 0)
                strncpy(msg, ln + 9, sizeof(msg) - 1);
            ln = strtok_r(NULL, "\n", &saveptr);
        }
        free(lines);
        free(content);

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", ts);
        printf("Message: %s\n", msg);
        first = 0;

        strncpy(current, par, sizeof(current) - 1);
    }

    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command> [args]\n");
        return 1;
    }

    if (strcmp(argv[1], "init") == 0)
        return cmd_init();
    if (strcmp(argv[1], "add") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit add <file>\n"); return 1; }
        return cmd_add(argv[2]);
    }
    if (strcmp(argv[1], "commit") == 0) {
        if (argc < 4 || strcmp(argv[2], "-m") != 0) {
            fprintf(stderr, "Usage: minigit commit -m \"<message>\"\n");
            return 1;
        }
        return cmd_commit(argv[3]);
    }
    if (strcmp(argv[1], "log") == 0)
        return cmd_log();

    fprintf(stderr, "Unknown command: %s\n", argv[1]);
    return 1;
}
