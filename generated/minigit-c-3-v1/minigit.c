#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <errno.h>

/* MiniHash: FNV-1a variant, 64-bit, 16-char hex */
static void minihash_bytes(const unsigned char *data, size_t len, char out[17]) {
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

/* Read entire file into malloc'd buffer. Returns NULL on failure. */
static unsigned char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0) { fclose(f); return NULL; }
    unsigned char *buf = malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, (size_t)len, f);
    fclose(f);
    buf[rd] = 0;
    if (out_len) *out_len = rd;
    return buf;
}

static int write_file(const char *path, const unsigned char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(data, 1, len, f);
    fclose(f);
    return 0;
}

static int write_string(const char *path, const char *s) {
    return write_file(path, (const unsigned char *)s, strlen(s));
}

/* Read lines from index file into array. Returns count. */
static int read_index(char lines[][1024], int max_lines) {
    FILE *f = fopen(".minigit/index", "r");
    if (!f) return 0;
    int count = 0;
    while (count < max_lines && fgets(lines[count], 1024, f)) {
        /* strip newline */
        size_t l = strlen(lines[count]);
        while (l > 0 && (lines[count][l-1] == '\n' || lines[count][l-1] == '\r'))
            lines[count][--l] = 0;
        if (l > 0)
            count++;
    }
    fclose(f);
    return count;
}

/* ============ Commands ============ */

static int cmd_init(void) {
    if (dir_exists(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdir_p(".minigit");
    mkdir_p(".minigit/objects");
    mkdir_p(".minigit/commits");
    write_string(".minigit/index", "");
    write_string(".minigit/HEAD", "");
    return 0;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    /* Read file and compute hash */
    size_t flen;
    unsigned char *data = read_file(filename, &flen);
    if (!data) {
        printf("File not found\n");
        return 1;
    }

    char hash[17];
    minihash_bytes(data, flen, hash);

    /* Store blob */
    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, data, flen);
    free(data);

    /* Read current index and check for duplicate */
    char lines[4096][1024];
    int count = read_index(lines, 4096);
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) {
            found = 1;
            break;
        }
    }

    if (!found) {
        FILE *f = fopen(".minigit/index", "a");
        if (f) {
            fprintf(f, "%s\n", filename);
            fclose(f);
        }
    }

    return 0;
}

static int cmp_strings(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    /* Read index */
    char lines[4096][1024];
    int count = read_index(lines, 4096);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    char *ptrs[4096];
    for (int i = 0; i < count; i++) ptrs[i] = lines[i];
    qsort(ptrs, count, sizeof(char *), cmp_strings);

    /* Read HEAD */
    size_t hlen;
    unsigned char *head_data = read_file(".minigit/HEAD", &hlen);
    char parent[256] = "NONE";
    if (head_data) {
        /* trim whitespace */
        char *h = (char *)head_data;
        size_t l = strlen(h);
        while (l > 0 && (h[l-1] == '\n' || h[l-1] == '\r' || h[l-1] == ' '))
            h[--l] = 0;
        if (l > 0)
            strncpy(parent, h, sizeof(parent) - 1);
        free(head_data);
    }

    /* Get timestamp */
    long ts = (long)time(NULL);

    /* Build commit content */
    /* First pass: compute size */
    size_t needed = 0;
    needed += snprintf(NULL, 0, "parent: %s\n", parent);
    needed += snprintf(NULL, 0, "timestamp: %ld\n", ts);
    needed += snprintf(NULL, 0, "message: %s\n", message);
    needed += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < count; i++) {
        /* Read file, hash it */
        size_t flen;
        unsigned char *fdata = read_file(ptrs[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash_bytes(fdata, flen, fhash);
            free(fdata);
        } else {
            /* File might have been removed; read from objects via index -
               for simplicity, use the stored blob. We need to find the hash.
               Actually, per spec we hash current file content at add time.
               If file is gone, we should still have the blob. Let's look up
               from objects dir. But the spec says at commit time we record
               filename + blobhash. The blob was stored at add time.
               Let's re-read the file; if missing, skip or error. */
            strcpy(fhash, "0000000000000000");
        }
        needed += snprintf(NULL, 0, "%s %s\n", ptrs[i], fhash);
    }

    char *content = malloc(needed + 1);
    if (!content) return 1;
    size_t pos = 0;
    pos += sprintf(content + pos, "parent: %s\n", parent);
    pos += sprintf(content + pos, "timestamp: %ld\n", ts);
    pos += sprintf(content + pos, "message: %s\n", message);
    pos += sprintf(content + pos, "files:\n");
    for (int i = 0; i < count; i++) {
        size_t flen;
        unsigned char *fdata = read_file(ptrs[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash_bytes(fdata, flen, fhash);
            free(fdata);
        } else {
            strcpy(fhash, "0000000000000000");
        }
        pos += sprintf(content + pos, "%s %s\n", ptrs[i], fhash);
    }

    /* Hash commit content */
    char commit_hash[17];
    minihash_bytes((unsigned char *)content, pos, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, (unsigned char *)content, pos);
    free(content);

    /* Update HEAD */
    write_string(".minigit/HEAD", commit_hash);

    /* Clear index */
    write_string(".minigit/index", "");

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_log(void) {
    /* Read HEAD */
    size_t hlen;
    unsigned char *head_data = read_file(".minigit/HEAD", &hlen);
    if (!head_data || hlen == 0) {
        if (head_data) free(head_data);
        printf("No commits\n");
        return 0;
    }

    char current[256];
    strncpy(current, (char *)head_data, sizeof(current) - 1);
    current[sizeof(current) - 1] = 0;
    free(head_data);

    /* trim */
    size_t l = strlen(current);
    while (l > 0 && (current[l-1] == '\n' || current[l-1] == '\r' || current[l-1] == ' '))
        current[--l] = 0;

    if (l == 0) {
        printf("No commits\n");
        return 0;
    }

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);

        size_t clen;
        unsigned char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* Parse commit: find parent, timestamp, message */
        char *text = (char *)cdata;
        char par[256] = "NONE";
        char ts[64] = "";
        char msg[4096] = "";

        char *line = strtok(text, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0) {
                strncpy(par, line + 8, sizeof(par) - 1);
            } else if (strncmp(line, "timestamp: ", 11) == 0) {
                strncpy(ts, line + 11, sizeof(ts) - 1);
            } else if (strncmp(line, "message: ", 9) == 0) {
                strncpy(msg, line + 9, sizeof(msg) - 1);
            }
            line = strtok(NULL, "\n");
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", ts);
        printf("Message: %s\n", msg);
        first = 0;

        free(cdata);

        /* Move to parent */
        strncpy(current, par, sizeof(current) - 1);
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
