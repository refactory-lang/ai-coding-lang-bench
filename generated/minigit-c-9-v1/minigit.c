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
    if (!f) return;
    fwrite(data, 1, len, f);
    fclose(f);
}

static void write_str(const char *path, const char *s) {
    write_file(path, s, strlen(s));
}

static int cmd_init(void) {
    if (is_dir(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdir_p(".minigit");
    mkdir_p(".minigit/objects");
    mkdir_p(".minigit/commits");
    write_str(".minigit/index", "");
    write_str(".minigit/HEAD", "");
    return 0;
}

/* Read index lines into array, return count */
static int read_index(char lines[][1024], int max) {
    size_t len;
    char *data = read_file(".minigit/index", &len);
    if (!data || len == 0) {
        free(data);
        return 0;
    }
    int count = 0;
    char *p = data;
    while (*p && count < max) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen > 0 && llen < 1024) {
            memcpy(lines[count], p, llen);
            lines[count][llen] = '\0';
            count++;
        }
        if (!nl) break;
        p = nl + 1;
    }
    free(data);
    return count;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    size_t len;
    char *data = read_file(filename, &len);
    if (!data) {
        printf("File not found\n");
        return 1;
    }

    char hash[17];
    minihash((unsigned char *)data, len, hash);

    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, data, len);
    free(data);

    /* Add to index if not present */
    char lines[4096][1024];
    int count = read_index(lines, 4096);
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0)
            return 0;
    }

    FILE *f = fopen(".minigit/index", "a");
    fprintf(f, "%s\n", filename);
    fclose(f);
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

static int cmd_commit(const char *message) {
    char lines[4096][1024];
    int count = read_index(lines, 4096);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(lines, count, sizeof(lines[0]), cmp_str);

    /* Read HEAD */
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    char parent[64] = "NONE";
    if (head && hlen > 0) {
        /* trim whitespace */
        char *e = head + hlen - 1;
        while (e >= head && (*e == '\n' || *e == '\r' || *e == ' ')) *e-- = '\0';
        if (strlen(head) > 0)
            strncpy(parent, head, sizeof(parent) - 1);
    }
    free(head);

    /* Get timestamp */
    time_t ts = time(NULL);

    /* Build commit content */
    /* First pass: compute size */
    size_t cap = 4096;
    char *content = malloc(cap);
    int pos = 0;

    pos += snprintf(content + pos, cap - pos, "parent: %s\n", parent);
    pos += snprintf(content + pos, cap - pos, "timestamp: %lld\n", (long long)ts);
    pos += snprintf(content + pos, cap - pos, "message: %s\n", message);
    pos += snprintf(content + pos, cap - pos, "files:\n");

    for (int i = 0; i < count; i++) {
        /* Hash the current file content */
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            /* File might have been deleted; use stored blob hash */
            /* For simplicity, skip */
            strcpy(fhash, "0000000000000000");
        }
        pos += snprintf(content + pos, cap - pos, "%s %s\n", lines[i], fhash);
    }

    /* Hash commit */
    char commit_hash[17];
    minihash((unsigned char *)content, pos, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, pos);
    free(content);

    /* Update HEAD */
    write_str(".minigit/HEAD", commit_hash);

    /* Clear index */
    write_str(".minigit/index", "");

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_log(void) {
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    if (!head || hlen == 0 || head[0] == '\0' || head[0] == '\n') {
        printf("No commits\n");
        free(head);
        return 0;
    }
    /* trim */
    char *e = head + strlen(head) - 1;
    while (e >= head && (*e == '\n' || *e == '\r' || *e == ' ')) *e-- = '\0';

    if (strlen(head) == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[64];
    strncpy(current, head, sizeof(current) - 1);
    current[63] = '\0';
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
            char *nl = strchr(line, '\n');
            size_t llen = nl ? (size_t)(nl - line) : strlen(line);
            char tmp[2048];
            if (llen >= sizeof(tmp)) llen = sizeof(tmp) - 1;
            memcpy(tmp, line, llen);
            tmp[llen] = '\0';

            if (strncmp(tmp, "parent: ", 8) == 0)
                strncpy(parent, tmp + 8, sizeof(parent) - 1);
            else if (strncmp(tmp, "timestamp: ", 11) == 0)
                strncpy(timestamp, tmp + 11, sizeof(timestamp) - 1);
            else if (strncmp(tmp, "message: ", 9) == 0)
                strncpy(message, tmp + 9, sizeof(message) - 1);
            else if (strncmp(tmp, "files:", 6) == 0) {
                /* stop parsing header */
                break;
            }

            if (!nl) break;
            line = nl + 1;
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        free(cdata);
        strncpy(current, parent, sizeof(current) - 1);
    }

    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command>\n");
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
