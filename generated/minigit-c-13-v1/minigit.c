#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

#define MINIGIT_DIR ".minigit"
#define OBJECTS_DIR ".minigit/objects"
#define COMMITS_DIR ".minigit/commits"
#define INDEX_FILE  ".minigit/index"
#define HEAD_FILE   ".minigit/HEAD"

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

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(1); }
    fwrite(data, 1, len, f);
    fclose(f);
}

static int dir_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static void mkdirp(const char *path) {
    mkdir(path, 0755);
}

/* Read index file, return array of lines and count */
static char **read_index(int *count) {
    *count = 0;
    size_t len;
    char *data = read_file(INDEX_FILE, &len);
    if (!data || len == 0) {
        free(data);
        return NULL;
    }
    /* Count lines */
    int cap = 64;
    char **lines = malloc(cap * sizeof(char *));
    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen == 0) { if (nl) { p = nl + 1; continue; } else break; }
        if (*count >= cap) { cap *= 2; lines = realloc(lines, cap * sizeof(char *)); }
        lines[*count] = strndup(p, llen);
        (*count)++;
        if (nl) p = nl + 1; else break;
    }
    free(data);
    return lines;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_init(void) {
    if (dir_exists(MINIGIT_DIR)) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdirp(MINIGIT_DIR);
    mkdirp(OBJECTS_DIR);
    mkdirp(COMMITS_DIR);
    write_file(INDEX_FILE, "", 0);
    write_file(HEAD_FILE, "", 0);
    return 0;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }
    /* Hash file content */
    size_t len;
    char *data = read_file(filename, &len);
    char hash[17];
    minihash((unsigned char *)data, len, hash);

    /* Store blob */
    char objpath[512];
    snprintf(objpath, sizeof(objpath), "%s/%s", OBJECTS_DIR, hash);
    write_file(objpath, data, len);
    free(data);

    /* Update index - add if not present */
    int count;
    char **lines = read_index(&count);
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) { found = 1; break; }
    }
    if (!found) {
        FILE *f = fopen(INDEX_FILE, "a");
        fprintf(f, "%s\n", filename);
        fclose(f);
    }
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_commit(const char *message) {
    int count;
    char **lines = read_index(&count);
    if (count == 0) {
        printf("Nothing to commit\n");
        free(lines);
        return 1;
    }

    /* Sort filenames */
    qsort(lines, count, sizeof(char *), cmp_str);

    /* Read HEAD */
    size_t head_len;
    char *head = read_file(HEAD_FILE, &head_len);
    const char *parent = (head && head_len > 0) ? head : "NONE";

    /* Get timestamp */
    time_t ts = time(NULL);

    /* Build commit content */
    /* First pass: compute size */
    size_t needed = 0;
    needed += snprintf(NULL, 0, "parent: %s\n", parent);
    needed += snprintf(NULL, 0, "timestamp: %ld\n", (long)ts);
    needed += snprintf(NULL, 0, "message: %s\n", message);
    needed += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < count; i++) {
        /* Read file and hash it */
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            /* File might have been removed, check objects via index.
               For simplicity, we look for the blob that was stored during add. */
            strcpy(fhash, "0000000000000000");
        }
        needed += snprintf(NULL, 0, "%s %s\n", lines[i], fhash);
    }

    char *commit_buf = malloc(needed + 1);
    char *p = commit_buf;
    p += sprintf(p, "parent: %s\n", parent);
    p += sprintf(p, "timestamp: %ld\n", (long)ts);
    p += sprintf(p, "message: %s\n", message);
    p += sprintf(p, "files:\n");
    for (int i = 0; i < count; i++) {
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char *)fdata, flen, fhash);
            free(fdata);
        } else {
            strcpy(fhash, "0000000000000000");
        }
        p += sprintf(p, "%s %s\n", lines[i], fhash);
    }

    size_t commit_len = p - commit_buf;

    /* Hash the commit */
    char commit_hash[17];
    minihash((unsigned char *)commit_buf, commit_len, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), "%s/%s", COMMITS_DIR, commit_hash);
    write_file(cpath, commit_buf, commit_len);

    /* Update HEAD */
    write_file(HEAD_FILE, commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(INDEX_FILE, "", 0);

    printf("Committed %s\n", commit_hash);

    free(commit_buf);
    free(head);
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_log(void) {
    size_t head_len;
    char *head = read_file(HEAD_FILE, &head_len);
    if (!head || head_len == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[17];
    strncpy(current, head, 16);
    current[16] = '\0';
    free(head);

    while (strlen(current) > 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), "%s/%s", COMMITS_DIR, current);
        size_t clen;
        char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* Parse commit */
        char parent[64] = "";
        char timestamp[64] = "";
        char message[1024] = "";

        char *line = strtok(cdata, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0) {
                strncpy(parent, line + 8, sizeof(parent) - 1);
            } else if (strncmp(line, "timestamp: ", 11) == 0) {
                strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
            } else if (strncmp(line, "message: ", 9) == 0) {
                strncpy(message, line + 9, sizeof(message) - 1);
            }
            line = strtok(NULL, "\n");
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

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command> [args]\n");
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
