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
    if (!f) { perror(path); exit(1); }
    fwrite(data, 1, len, f);
    fclose(f);
}

static int cmd_init(void) {
    if (is_dir(MINIGIT_DIR)) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdir_p(MINIGIT_DIR);
    mkdir_p(OBJECTS_DIR);
    mkdir_p(COMMITS_DIR);
    write_file(INDEX_FILE, "", 0);
    write_file(HEAD_FILE, "", 0);
    return 0;
}

/* Read index lines into array, return count */
static int read_index(char ***lines_out) {
    size_t len;
    char *data = read_file(INDEX_FILE, &len);
    if (!data || len == 0) {
        free(data);
        *lines_out = NULL;
        return 0;
    }
    /* count lines */
    int count = 0;
    int cap = 64;
    char **lines = malloc(cap * sizeof(char *));
    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen > 0) {
            if (count >= cap) { cap *= 2; lines = realloc(lines, cap * sizeof(char *)); }
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
    snprintf(objpath, sizeof(objpath), "%s/%s", OBJECTS_DIR, hash);
    write_file(objpath, data, len);
    free(data);

    /* Check if already in index */
    char **lines;
    int count = read_index(&lines);
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) found = 1;
        free(lines[i]);
    }
    free(lines);

    if (!found) {
        FILE *f = fopen(INDEX_FILE, "a");
        fprintf(f, "%s\n", filename);
        fclose(f);
    }
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static int cmd_commit(const char *message) {
    char **files;
    int nfiles = read_index(&files);
    if (nfiles == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(files, nfiles, sizeof(char *), cmp_str);

    /* Read HEAD */
    size_t headlen;
    char *head = read_file(HEAD_FILE, &headlen);
    const char *parent = (head && headlen > 0) ? head : "NONE";

    /* Build commit content */
    /* First pass: compute size */
    size_t sz = 0;
    sz += snprintf(NULL, 0, "parent: %s\n", parent);
    long ts = (long)time(NULL);
    sz += snprintf(NULL, 0, "timestamp: %ld\n", ts);
    sz += snprintf(NULL, 0, "message: %s\n", message);
    sz += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < nfiles; i++) {
        size_t flen;
        char *fdata = read_file(files[i], &flen);
        char fhash[17];
        minihash((unsigned char *)fdata, flen, fhash);
        free(fdata);
        sz += snprintf(NULL, 0, "%s %s\n", files[i], fhash);
    }

    char *content = malloc(sz + 1);
    size_t pos = 0;
    pos += sprintf(content + pos, "parent: %s\n", parent);
    pos += sprintf(content + pos, "timestamp: %ld\n", ts);
    pos += sprintf(content + pos, "message: %s\n", message);
    pos += sprintf(content + pos, "files:\n");
    for (int i = 0; i < nfiles; i++) {
        size_t flen;
        char *fdata = read_file(files[i], &flen);
        char fhash[17];
        minihash((unsigned char *)fdata, flen, fhash);
        free(fdata);
        pos += sprintf(content + pos, "%s %s\n", files[i], fhash);
    }

    char commit_hash[17];
    minihash((unsigned char *)content, pos, commit_hash);

    char commitpath[512];
    snprintf(commitpath, sizeof(commitpath), "%s/%s", COMMITS_DIR, commit_hash);
    write_file(commitpath, content, pos);

    write_file(HEAD_FILE, commit_hash, strlen(commit_hash));
    write_file(INDEX_FILE, "", 0);

    printf("Committed %s\n", commit_hash);

    for (int i = 0; i < nfiles; i++) free(files[i]);
    free(files);
    free(content);
    free(head);
    return 0;
}

static int cmd_log(void) {
    size_t headlen;
    char *head = read_file(HEAD_FILE, &headlen);
    if (!head || headlen == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[17];
    strncpy(current, head, 16);
    current[16] = '\0';
    free(head);

    int first = 1;
    while (strcmp(current, "") != 0 && strcmp(current, "NONE") != 0) {
        char path[512];
        snprintf(path, sizeof(path), "%s/%s", COMMITS_DIR, current);
        size_t len;
        char *data = read_file(path, &len);
        if (!data) break;

        /* Parse parent, timestamp, message */
        char parent[64] = "NONE";
        char timestamp[64] = "";
        char message[1024] = "";

        char *line = strtok(data, "\n");
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

        if (strcmp(parent, "NONE") == 0) break;
        strncpy(current, parent, 16);
        current[16] = '\0';

        free(data);
    }
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command>\n");
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
