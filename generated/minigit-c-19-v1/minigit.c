#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>

#define MAX_PATH 4096
#define MAX_LINE 4096
#define MAX_FILES 1024

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

static unsigned char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(sz + 1);
    if (sz > 0) {
        size_t r = fread(buf, 1, sz, f);
        (void)r;
    }
    buf[sz] = 0;
    fclose(f);
    *out_len = (size_t)sz;
    return buf;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror("fopen"); exit(1); }
    fwrite(data, 1, len, f);
    fclose(f);
}

static int read_lines(const char *path, char lines[][MAX_PATH], int max) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int count = 0;
    while (count < max && fgets(lines[count], MAX_PATH, f)) {
        /* strip newline */
        size_t l = strlen(lines[count]);
        while (l > 0 && (lines[count][l-1] == '\n' || lines[count][l-1] == '\r'))
            lines[count][--l] = 0;
        if (l > 0) count++;
    }
    fclose(f);
    return count;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

/* ---- commands ---- */

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

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }
    /* hash file content */
    size_t len;
    unsigned char *data = read_file(filename, &len);
    char hash[17];
    minihash(data, len, hash);

    /* write object */
    char objpath[MAX_PATH];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, (char *)data, len);
    free(data);

    /* update index: add filename if not present */
    char lines[MAX_FILES][MAX_PATH];
    int count = read_lines(".minigit/index", lines, MAX_FILES);
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) return 0;
    }
    FILE *f = fopen(".minigit/index", "a");
    fprintf(f, "%s\n", filename);
    fclose(f);
    return 0;
}

static int cmd_commit(const char *message) {
    /* read index */
    char lines[MAX_FILES][MAX_PATH];
    int count = read_lines(".minigit/index", lines, MAX_FILES);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* read HEAD */
    char head[MAX_PATH] = "";
    {
        size_t hlen;
        unsigned char *hdata = read_file(".minigit/HEAD", &hlen);
        if (hdata) {
            /* trim */
            while (hlen > 0 && (hdata[hlen-1] == '\n' || hdata[hlen-1] == '\r'))
                hlen--;
            if (hlen > 0 && hlen < sizeof(head)) {
                memcpy(head, hdata, hlen);
                head[hlen] = 0;
            }
            free(hdata);
        }
    }

    const char *parent = (head[0] ? head : "NONE");

    /* sort filenames */
    char *sorted[MAX_FILES];
    for (int i = 0; i < count; i++) sorted[i] = lines[i];
    qsort(sorted, count, sizeof(char *), cmp_str);

    /* build commit content */
    char commit_buf[65536];
    int pos = 0;
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "parent: %s\n", parent);
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "timestamp: %ld\n", (long)time(NULL));
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "message: %s\n", message);
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "files:\n");

    for (int i = 0; i < count; i++) {
        /* hash the file */
        size_t flen;
        unsigned char *fdata = read_file(sorted[i], &flen);
        if (!fdata) {
            /* file may have been deleted; read from objects - skip for now, use empty */
            pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "%s 0000000000000000\n", sorted[i]);
            continue;
        }
        char fhash[17];
        minihash(fdata, flen, fhash);
        free(fdata);
        pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "%s %s\n", sorted[i], fhash);
    }

    /* hash commit */
    char commit_hash[17];
    minihash((unsigned char *)commit_buf, pos, commit_hash);

    /* write commit file */
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, commit_buf, pos);

    /* update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_log(void) {
    /* read HEAD */
    size_t hlen;
    unsigned char *hdata = read_file(".minigit/HEAD", &hlen);
    if (!hdata || hlen == 0) {
        printf("No commits\n");
        free(hdata);
        return 0;
    }
    /* trim */
    while (hlen > 0 && (hdata[hlen-1] == '\n' || hdata[hlen-1] == '\r'))
        hlen--;
    if (hlen == 0) {
        printf("No commits\n");
        free(hdata);
        return 0;
    }

    char current[MAX_PATH];
    memcpy(current, hdata, hlen);
    current[hlen] = 0;
    free(hdata);

    int first = 1;
    while (current[0]) {
        char cpath[MAX_PATH];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        size_t clen;
        unsigned char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* parse commit */
        char *text = (char *)cdata;
        char parent[MAX_PATH] = "";
        char timestamp[MAX_PATH] = "";
        char message[MAX_PATH] = "";

        char *line = strtok(text, "\n");
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

        free(cdata);

        if (strcmp(parent, "NONE") == 0 || parent[0] == 0)
            break;
        strncpy(current, parent, sizeof(current) - 1);
        current[sizeof(current) - 1] = 0;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command>\n");
        return 1;
    }
    const char *cmd = argv[1];

    if (strcmp(cmd, "init") == 0) {
        return cmd_init();
    } else if (strcmp(cmd, "add") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit add <file>\n"); return 1; }
        return cmd_add(argv[2]);
    } else if (strcmp(cmd, "commit") == 0) {
        if (argc < 4 || strcmp(argv[2], "-m") != 0) {
            fprintf(stderr, "Usage: minigit commit -m \"<message>\"\n");
            return 1;
        }
        return cmd_commit(argv[3]);
    } else if (strcmp(cmd, "log") == 0) {
        return cmd_log();
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
}
