#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <time.h>

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
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = 0;
    fclose(f);
    if (out_len) *out_len = rd;
    return buf;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
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

/* Read index file, return number of entries. entries[] filled with strdup'd strings. */
static int read_index(char *entries[], int max) {
    int count = 0;
    FILE *f = fopen(".minigit/index", "r");
    if (!f) return 0;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f) && count < max) {
        /* strip newline */
        size_t l = strlen(line);
        while (l > 0 && (line[l-1] == '\n' || line[l-1] == '\r')) line[--l] = 0;
        if (l > 0) {
            entries[count++] = strdup(line);
        }
    }
    fclose(f);
    return count;
}

static void write_index(char *entries[], int count) {
    FILE *f = fopen(".minigit/index", "w");
    if (!f) return;
    for (int i = 0; i < count; i++) {
        fprintf(f, "%s\n", entries[i]);
    }
    fclose(f);
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    size_t len;
    unsigned char *data = read_file(filename, &len);
    if (!data) {
        printf("File not found\n");
        return 1;
    }

    char hash[17];
    minihash(data, len, hash);

    /* Write blob */
    char objpath[MAX_LINE];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, (char *)data, len);
    free(data);

    /* Update index */
    char *entries[MAX_FILES];
    int count = read_index(entries, MAX_FILES);

    /* Check if already in index */
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(entries[i], filename) == 0) {
            found = 1;
            break;
        }
    }
    if (!found) {
        entries[count++] = strdup(filename);
        write_index(entries, count);
    }

    for (int i = 0; i < count; i++) free(entries[i]);
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    char *entries[MAX_FILES];
    int count = read_index(entries, MAX_FILES);

    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(entries, count, sizeof(char *), cmp_str);

    /* Read HEAD */
    size_t head_len;
    unsigned char *head_raw = read_file(".minigit/HEAD", &head_len);
    char parent[64] = "NONE";
    if (head_raw) {
        /* strip whitespace */
        char *p = (char *)head_raw;
        size_t pl = strlen(p);
        while (pl > 0 && (p[pl-1] == '\n' || p[pl-1] == '\r' || p[pl-1] == ' ')) p[--pl] = 0;
        if (pl > 0) {
            strncpy(parent, p, sizeof(parent) - 1);
            parent[sizeof(parent) - 1] = 0;
        }
        free(head_raw);
    }

    /* Get timestamp */
    time_t now = time(NULL);

    /* Build commit content */
    /* First pass: compute size */
    size_t content_size = 0;
    content_size += snprintf(NULL, 0, "parent: %s\n", parent);
    content_size += snprintf(NULL, 0, "timestamp: %ld\n", (long)now);
    content_size += snprintf(NULL, 0, "message: %s\n", message);
    content_size += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < count; i++) {
        /* Read file content to get hash */
        size_t flen;
        unsigned char *fdata = read_file(entries[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash(fdata, flen, fhash);
            free(fdata);
        } else {
            /* Try from objects - find blob for this file from a previous add */
            /* Actually, the blob should exist already. Let's look for it. */
            fhash[0] = 0;
        }
        content_size += snprintf(NULL, 0, "%s %s\n", entries[i], fhash);
    }

    char *content = malloc(content_size + 1);
    size_t pos = 0;
    pos += sprintf(content + pos, "parent: %s\n", parent);
    pos += sprintf(content + pos, "timestamp: %ld\n", (long)now);
    pos += sprintf(content + pos, "message: %s\n", message);
    pos += sprintf(content + pos, "files:\n");
    for (int i = 0; i < count; i++) {
        size_t flen;
        unsigned char *fdata = read_file(entries[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash(fdata, flen, fhash);
            free(fdata);
        } else {
            strcpy(fhash, "0000000000000000");
        }
        pos += sprintf(content + pos, "%s %s\n", entries[i], fhash);
    }

    /* Hash the commit content */
    char commit_hash[17];
    minihash((unsigned char *)content, pos, commit_hash);

    /* Write commit file */
    char cpath[MAX_LINE];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, pos);
    free(content);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    for (int i = 0; i < count; i++) free(entries[i]);
    return 0;
}

static int cmd_log(void) {
    size_t head_len;
    unsigned char *head_raw = read_file(".minigit/HEAD", &head_len);
    if (!head_raw || head_len == 0) {
        printf("No commits\n");
        free(head_raw);
        return 0;
    }

    char current[64];
    strncpy(current, (char *)head_raw, sizeof(current) - 1);
    current[sizeof(current) - 1] = 0;
    /* strip whitespace */
    size_t cl = strlen(current);
    while (cl > 0 && (current[cl-1] == '\n' || current[cl-1] == '\r' || current[cl-1] == ' ')) current[--cl] = 0;
    free(head_raw);

    if (cl == 0) {
        printf("No commits\n");
        return 0;
    }

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[MAX_LINE];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        size_t clen;
        unsigned char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* Parse commit */
        char *text = (char *)cdata;
        char parent[64] = "NONE";
        char timestamp[64] = "";
        char message[MAX_LINE] = "";

        char *line = strtok(text, "\n");
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

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        free(cdata);

        strncpy(current, parent, sizeof(current) - 1);
        current[sizeof(current) - 1] = 0;
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
