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

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    if (sz > 0) {
        size_t rd = fread(buf, 1, sz, f);
        (void)rd;
    }
    buf[sz] = '\0';
    fclose(f);
    if (out_len) *out_len = (size_t)sz;
    return buf;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror("fopen"); exit(1); }
    if (len > 0) fwrite(data, 1, len, f);
    fclose(f);
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

/* Read index file, return array of lines. Caller frees. */
static int read_index(char ***lines_out) {
    size_t len;
    char *data = read_file(".minigit/index", &len);
    if (!data || len == 0) {
        free(data);
        *lines_out = NULL;
        return 0;
    }
    /* Count lines */
    int count = 0;
    int cap = 64;
    char **lines = malloc(cap * sizeof(char *));
    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen;
        if (nl) {
            llen = nl - p;
        } else {
            llen = strlen(p);
        }
        if (llen > 0) {
            if (count >= cap) {
                cap *= 2;
                lines = realloc(lines, cap * sizeof(char *));
            }
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

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

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

    /* Write blob */
    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, data, len);
    free(data);

    /* Update index: append if not present */
    char **lines;
    int count = read_index(&lines);
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) {
            found = 1;
            break;
        }
    }

    if (!found) {
        FILE *f = fopen(".minigit/index", "a");
        fprintf(f, "%s\n", filename);
        fclose(f);
    }

    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_commit(const char *message) {
    /* Read index */
    char **lines;
    int count = read_index(&lines);
    if (count == 0) {
        printf("Nothing to commit\n");
        free(lines);
        return 1;
    }

    /* Sort filenames */
    qsort(lines, count, sizeof(char *), cmp_str);

    /* Read HEAD */
    size_t head_len;
    char *head = read_file(".minigit/HEAD", &head_len);
    char parent[64];
    if (!head || head_len == 0 || head[0] == '\0' || head[0] == '\n') {
        strcpy(parent, "NONE");
    } else {
        /* Trim newline */
        char *nl = strchr(head, '\n');
        if (nl) *nl = '\0';
        strncpy(parent, head, sizeof(parent) - 1);
        parent[sizeof(parent) - 1] = '\0';
    }
    free(head);

    /* Get timestamp */
    long ts = (long)time(NULL);

    /* Build commit content */
    /* First pass: compute needed size */
    size_t needed = 0;
    needed += snprintf(NULL, 0, "parent: %s\n", parent);
    needed += snprintf(NULL, 0, "timestamp: %ld\n", ts);
    needed += snprintf(NULL, 0, "message: %s\n", message);
    needed += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < count; i++) {
        /* Read file content to get hash */
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        if (!fdata) {
            /* File might have been deleted, use blob from objects */
            /* Skip for now - spec says files should exist */
            needed += snprintf(NULL, 0, "%s unknown\n", lines[i]);
            continue;
        }
        char hash[17];
        minihash((unsigned char *)fdata, flen, hash);
        free(fdata);
        needed += snprintf(NULL, 0, "%s %s\n", lines[i], hash);
    }

    char *content = malloc(needed + 1);
    size_t pos = 0;
    pos += sprintf(content + pos, "parent: %s\n", parent);
    pos += sprintf(content + pos, "timestamp: %ld\n", ts);
    pos += sprintf(content + pos, "message: %s\n", message);
    pos += sprintf(content + pos, "files:\n");
    for (int i = 0; i < count; i++) {
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        if (!fdata) {
            pos += sprintf(content + pos, "%s unknown\n", lines[i]);
            continue;
        }
        char hash[17];
        minihash((unsigned char *)fdata, flen, hash);
        free(fdata);
        pos += sprintf(content + pos, "%s %s\n", lines[i], hash);
    }

    /* Hash commit content */
    char commit_hash[17];
    minihash((unsigned char *)content, pos, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, pos);
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
    size_t head_len;
    char *head = read_file(".minigit/HEAD", &head_len);
    if (!head || head_len == 0 || head[0] == '\0' || head[0] == '\n') {
        printf("No commits\n");
        free(head);
        return 0;
    }

    /* Trim newline from HEAD */
    char *nl = strchr(head, '\n');
    if (nl) *nl = '\0';

    char current[64];
    strncpy(current, head, sizeof(current) - 1);
    current[sizeof(current) - 1] = '\0';
    free(head);

    int first = 1;
    while (strcmp(current, "NONE") != 0 && strlen(current) > 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);

        size_t clen;
        char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* Parse commit */
        char parent[64] = "NONE";
        char timestamp[64] = "";
        char message[1024] = "";

        char *line = cdata;
        while (line && *line) {
            char *eol = strchr(line, '\n');
            size_t llen;
            if (eol) {
                llen = eol - line;
            } else {
                llen = strlen(line);
            }

            if (strncmp(line, "parent: ", 8) == 0) {
                size_t vlen = llen - 8;
                if (vlen >= sizeof(parent)) vlen = sizeof(parent) - 1;
                memcpy(parent, line + 8, vlen);
                parent[vlen] = '\0';
            } else if (strncmp(line, "timestamp: ", 11) == 0) {
                size_t vlen = llen - 11;
                if (vlen >= sizeof(timestamp)) vlen = sizeof(timestamp) - 1;
                memcpy(timestamp, line + 11, vlen);
                timestamp[vlen] = '\0';
            } else if (strncmp(line, "message: ", 9) == 0) {
                size_t vlen = llen - 9;
                if (vlen >= sizeof(message)) vlen = sizeof(message) - 1;
                memcpy(message, line + 9, vlen);
                message[vlen] = '\0';
            }

            if (eol) line = eol + 1; else break;
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        free(cdata);
        strncpy(current, parent, sizeof(current) - 1);
        current[sizeof(current) - 1] = '\0';
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
    } else if (strcmp(argv[1], "log") == 0) {
        return cmd_log();
    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
        return 1;
    }
}
