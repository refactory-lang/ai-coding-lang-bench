#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <errno.h>

#define HASH_LEN 16
#define PATH_MAX_LEN 4096
#define LINE_MAX_LEN 4096

/* MiniHash: FNV-1a variant, 64-bit, 16-char hex output */
static void minihash(const unsigned char *data, size_t len, char *out) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= data[i];
        h *= 1099511628211ULL;
    }
    snprintf(out, HASH_LEN + 1, "%016llx", (unsigned long long)h);
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
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    fclose(f);
    if (out_len) *out_len = rd;
    return buf;
}

static int write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(data, 1, len, f);
    fclose(f);
    return 0;
}

/* Read lines from a file into an array. Returns count. */
static int read_lines(const char *path, char lines[][LINE_MAX_LEN], int max_lines) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int count = 0;
    while (count < max_lines && fgets(lines[count], LINE_MAX_LEN, f)) {
        /* strip newline */
        size_t len = strlen(lines[count]);
        while (len > 0 && (lines[count][len-1] == '\n' || lines[count][len-1] == '\r'))
            lines[count][--len] = '\0';
        if (len > 0)
            count++;
    }
    fclose(f);
    return count;
}

static int cmd_init(void) {
    if (is_dir(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdir_p(".minigit");
    mkdir_p(".minigit/objects");
    mkdir_p(".minigit/commits");
    /* create empty index and HEAD */
    write_file(".minigit/index", "", 0);
    write_file(".minigit/HEAD", "", 0);
    return 0;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }
    /* Read file and hash */
    size_t flen;
    unsigned char *data = read_file(filename, &flen);
    if (!data) {
        printf("File not found\n");
        return 1;
    }
    char hash[HASH_LEN + 1];
    minihash(data, flen, hash);

    /* Write blob */
    char obj_path[PATH_MAX_LEN];
    snprintf(obj_path, sizeof(obj_path), ".minigit/objects/%s", hash);
    write_file(obj_path, (char *)data, flen);
    free(data);

    /* Update index: add filename if not already present */
    char lines[1024][LINE_MAX_LEN];
    int count = read_lines(".minigit/index", lines, 1024);

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

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    /* Read index */
    char lines[1024][LINE_MAX_LEN];
    int count = read_lines(".minigit/index", lines, 1024);

    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Read HEAD */
    size_t head_len;
    unsigned char *head_data = read_file(".minigit/HEAD", &head_len);
    char parent[64] = "NONE";
    if (head_data) {
        /* strip whitespace */
        char *p = (char *)head_data;
        while (*p && *p != '\n' && *p != '\r') p++;
        *p = '\0';
        if (strlen((char *)head_data) > 0)
            strncpy(parent, (char *)head_data, sizeof(parent) - 1);
        free(head_data);
    }

    /* Sort filenames */
    char *sorted[1024];
    for (int i = 0; i < count; i++)
        sorted[i] = lines[i];
    qsort(sorted, count, sizeof(char *), cmp_str);

    /* Build commit content */
    /* First pass: compute file hashes */
    char file_hashes[1024][HASH_LEN + 1];
    for (int i = 0; i < count; i++) {
        /* Re-hash the current file content to get the blob hash */
        size_t flen;
        unsigned char *fdata = read_file(sorted[i], &flen);
        if (fdata) {
            minihash(fdata, flen, file_hashes[i]);
            free(fdata);
        } else {
            /* File might have been removed; try to find it in objects via index */
            /* For simplicity, hash whatever was staged */
            strcpy(file_hashes[i], "0000000000000000");
        }
    }

    /* Build commit string */
    char commit_buf[65536];
    int offset = 0;
    long ts = (long)time(NULL);

    offset += snprintf(commit_buf + offset, sizeof(commit_buf) - offset,
        "parent: %s\n", parent);
    offset += snprintf(commit_buf + offset, sizeof(commit_buf) - offset,
        "timestamp: %ld\n", ts);
    offset += snprintf(commit_buf + offset, sizeof(commit_buf) - offset,
        "message: %s\n", message);
    offset += snprintf(commit_buf + offset, sizeof(commit_buf) - offset,
        "files:\n");

    for (int i = 0; i < count; i++) {
        offset += snprintf(commit_buf + offset, sizeof(commit_buf) - offset,
            "%s %s\n", sorted[i], file_hashes[i]);
    }

    /* Hash commit content */
    char commit_hash[HASH_LEN + 1];
    minihash((unsigned char *)commit_buf, offset, commit_hash);

    /* Write commit file */
    char commit_path[PATH_MAX_LEN];
    snprintf(commit_path, sizeof(commit_path), ".minigit/commits/%s", commit_hash);
    write_file(commit_path, commit_buf, offset);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_log(void) {
    /* Read HEAD */
    size_t head_len;
    unsigned char *head_data = read_file(".minigit/HEAD", &head_len);
    if (!head_data || head_len == 0) {
        printf("No commits\n");
        free(head_data);
        return 0;
    }

    char current[64];
    /* strip whitespace */
    char *p = (char *)head_data;
    while (*p && *p != '\n' && *p != '\r') p++;
    *p = '\0';
    if (strlen((char *)head_data) == 0) {
        printf("No commits\n");
        free(head_data);
        return 0;
    }
    strncpy(current, (char *)head_data, sizeof(current) - 1);
    current[sizeof(current) - 1] = '\0';
    free(head_data);

    int first = 1;
    while (strcmp(current, "NONE") != 0 && strlen(current) > 0) {
        char commit_path[PATH_MAX_LEN];
        snprintf(commit_path, sizeof(commit_path), ".minigit/commits/%s", current);

        size_t clen;
        unsigned char *cdata = read_file(commit_path, &clen);
        if (!cdata) break;

        /* Parse commit: extract parent, timestamp, message */
        char par[64] = "NONE";
        char timestamp[64] = "";
        char msg[LINE_MAX_LEN] = "";

        char *line = strtok((char *)cdata, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0)
                strncpy(par, line + 8, sizeof(par) - 1);
            else if (strncmp(line, "timestamp: ", 11) == 0)
                strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
            else if (strncmp(line, "message: ", 9) == 0)
                strncpy(msg, line + 9, sizeof(msg) - 1);
            line = strtok(NULL, "\n");
        }

        if (!first)
            printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", msg);
        first = 0;

        strncpy(current, par, sizeof(current) - 1);
        free(cdata);
    }

    return 0;
}

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
