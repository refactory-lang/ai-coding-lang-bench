#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <time.h>

#define MAX_PATH 4096
#define MAX_LINE 4096
#define MAX_FILES 1024

/* MiniHash: FNV-1a variant, 64-bit, 16-char hex */
static void minihash_bytes(const unsigned char *data, size_t len, char out[17]) {
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
    size_t rd = fread(buf, 1, sz, f);
    fclose(f);
    minihash_bytes(buf, rd, out);
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

/* Read entire file into malloc'd buffer, set *len. Returns NULL on failure. */
static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    if (len) *len = rd;
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

/* ========== INIT ========== */
static int cmd_init(void) {
    if (dir_exists(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdirp(".minigit");
    mkdirp(".minigit/objects");
    mkdirp(".minigit/commits");
    write_str(".minigit/index", "");
    write_str(".minigit/HEAD", "");
    return 0;
}

/* ========== ADD ========== */
static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    /* Hash and store blob */
    char hash[17];
    minihash_file(filename, hash);

    char objpath[MAX_PATH];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);

    if (!file_exists(objpath)) {
        /* Copy file content to object */
        size_t len;
        char *data = read_file(filename, &len);
        if (data) {
            write_file(objpath, data, len);
            free(data);
        }
    }

    /* Add to index if not already present */
    char *idx = read_file(".minigit/index", NULL);
    if (!idx) idx = strdup("");

    /* Check if filename already in index */
    int found = 0;
    char *line = strtok(strdup(idx), "\n");
    while (line) {
        if (strcmp(line, filename) == 0) { found = 1; break; }
        line = strtok(NULL, "\n");
    }

    if (!found) {
        FILE *f = fopen(".minigit/index", "a");
        if (f) {
            fprintf(f, "%s\n", filename);
            fclose(f);
        }
    }

    free(idx);
    return 0;
}

/* ========== COMMIT ========== */
static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    /* Read index */
    char *idx = read_file(".minigit/index", NULL);
    if (!idx || strlen(idx) == 0) {
        printf("Nothing to commit\n");
        free(idx);
        return 1;
    }

    /* Parse filenames from index */
    char *files[MAX_FILES];
    int nfiles = 0;
    char *copy = strdup(idx);
    char *tok = strtok(copy, "\n");
    while (tok && nfiles < MAX_FILES) {
        if (strlen(tok) > 0) {
            files[nfiles++] = strdup(tok);
        }
        tok = strtok(NULL, "\n");
    }
    free(copy);

    if (nfiles == 0) {
        printf("Nothing to commit\n");
        free(idx);
        return 1;
    }

    /* Sort filenames */
    qsort(files, nfiles, sizeof(char *), cmp_str);

    /* Read HEAD (parent) */
    char *head = read_file(".minigit/HEAD", NULL);
    if (!head) head = strdup("");
    /* Trim newline */
    size_t hlen = strlen(head);
    while (hlen > 0 && (head[hlen-1] == '\n' || head[hlen-1] == '\r')) head[--hlen] = '\0';

    const char *parent = (strlen(head) > 0) ? head : "NONE";

    /* Timestamp */
    long ts = (long)time(NULL);

    /* Build commit content */
    /* First pass: calculate size */
    size_t csize = 0;
    csize += snprintf(NULL, 0, "parent: %s\n", parent);
    csize += snprintf(NULL, 0, "timestamp: %ld\n", ts);
    csize += snprintf(NULL, 0, "message: %s\n", message);
    csize += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < nfiles; i++) {
        char fhash[17];
        minihash_file(files[i], fhash);
        csize += snprintf(NULL, 0, "%s %s\n", files[i], fhash);
    }

    char *content = malloc(csize + 1);
    char *p = content;
    p += sprintf(p, "parent: %s\n", parent);
    p += sprintf(p, "timestamp: %ld\n", ts);
    p += sprintf(p, "message: %s\n", message);
    p += sprintf(p, "files:\n");
    for (int i = 0; i < nfiles; i++) {
        char fhash[17];
        minihash_file(files[i], fhash);
        p += sprintf(p, "%s %s\n", files[i], fhash);
    }

    /* Hash commit content */
    char chash[17];
    minihash_bytes((unsigned char *)content, strlen(content), chash);

    /* Write commit file */
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", chash);
    write_file(cpath, content, strlen(content));

    /* Update HEAD */
    write_str(".minigit/HEAD", chash);

    /* Clear index */
    write_str(".minigit/index", "");

    printf("Committed %s\n", chash);

    free(content);
    free(head);
    free(idx);
    for (int i = 0; i < nfiles; i++) free(files[i]);

    return 0;
}

/* ========== LOG ========== */
static int cmd_log(void) {
    char *head = read_file(".minigit/HEAD", NULL);
    if (!head || strlen(head) == 0 || head[0] == '\n') {
        printf("No commits\n");
        free(head);
        return 0;
    }
    /* Trim */
    size_t hlen = strlen(head);
    while (hlen > 0 && (head[hlen-1] == '\n' || head[hlen-1] == '\r')) head[--hlen] = '\0';
    if (strlen(head) == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[17];
    strncpy(current, head, 16);
    current[16] = '\0';
    free(head);

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[MAX_PATH];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);

        char *data = read_file(cpath, NULL);
        if (!data) break;

        /* Parse timestamp and message */
        char parent[64] = "";
        char timestamp[64] = "";
        char msg[MAX_LINE] = "";

        char *line = strtok(strdup(data), "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0) {
                strncpy(parent, line + 8, sizeof(parent) - 1);
            } else if (strncmp(line, "timestamp: ", 11) == 0) {
                strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
            } else if (strncmp(line, "message: ", 9) == 0) {
                strncpy(msg, line + 9, sizeof(msg) - 1);
            }
            line = strtok(NULL, "\n");
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", msg);
        first = 0;

        /* Move to parent */
        if (strcmp(parent, "NONE") == 0 || strlen(parent) == 0) break;
        strncpy(current, parent, 16);
        current[16] = '\0';

        free(data);
    }

    return 0;
}

/* ========== MAIN ========== */
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
    } else if (strcmp(cmd, "log") == 0) {
        return cmd_log();
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
}
