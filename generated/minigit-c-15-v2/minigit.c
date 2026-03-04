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

static int cmd_status(void) {
    char **lines;
    int count = read_index(&lines);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++) {
            printf("%s\n", lines[i]);
            free(lines[i]);
        }
        free(lines);
    }
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

/* Parse commit file to extract file entries. Returns count. */
typedef struct {
    char filename[256];
    char hash[17];
} commit_file_entry;

static int parse_commit_files(const char *commit_hash, commit_file_entry **entries_out,
                               char *parent_out, char *timestamp_out, char *message_out) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", COMMITS_DIR, commit_hash);
    size_t len;
    char *data = read_file(path, &len);
    if (!data) return -1;

    if (parent_out) parent_out[0] = '\0';
    if (timestamp_out) timestamp_out[0] = '\0';
    if (message_out) message_out[0] = '\0';

    int in_files = 0;
    int count = 0;
    int cap = 64;
    commit_file_entry *entries = malloc(cap * sizeof(commit_file_entry));

    /* Parse line by line without strtok (to avoid issues) */
    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        char line[2048];
        if (llen >= sizeof(line)) llen = sizeof(line) - 1;
        memcpy(line, p, llen);
        line[llen] = '\0';

        if (!in_files) {
            if (strcmp(line, "files:") == 0) {
                in_files = 1;
            } else if (strncmp(line, "parent: ", 8) == 0 && parent_out) {
                strncpy(parent_out, line + 8, 63);
            } else if (strncmp(line, "timestamp: ", 11) == 0 && timestamp_out) {
                strncpy(timestamp_out, line + 11, 63);
            } else if (strncmp(line, "message: ", 9) == 0 && message_out) {
                strncpy(message_out, line + 9, 1023);
            }
        } else {
            if (llen > 0) {
                /* parse "filename hash" */
                char *sp = strrchr(line, ' ');
                if (sp && (sp - line) > 0) {
                    if (count >= cap) { cap *= 2; entries = realloc(entries, cap * sizeof(commit_file_entry)); }
                    *sp = '\0';
                    strncpy(entries[count].filename, line, 255);
                    entries[count].filename[255] = '\0';
                    strncpy(entries[count].hash, sp + 1, 16);
                    entries[count].hash[16] = '\0';
                    count++;
                }
            }
        }
        if (nl) p = nl + 1; else break;
    }

    free(data);
    *entries_out = entries;
    return count;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    commit_file_entry *entries1 = NULL, *entries2 = NULL;
    int n1 = parse_commit_files(hash1, &entries1, NULL, NULL, NULL);
    if (n1 < 0) {
        printf("Invalid commit\n");
        free(entries1);
        return 1;
    }
    int n2 = parse_commit_files(hash2, &entries2, NULL, NULL, NULL);
    if (n2 < 0) {
        printf("Invalid commit\n");
        free(entries1);
        free(entries2);
        return 1;
    }

    /* Collect all filenames, sort */
    int total = n1 + n2;
    char **allnames = malloc((total + 1) * sizeof(char *));
    int nall = 0;
    for (int i = 0; i < n1; i++) {
        int dup = 0;
        for (int j = 0; j < nall; j++) if (strcmp(allnames[j], entries1[i].filename) == 0) { dup = 1; break; }
        if (!dup) allnames[nall++] = entries1[i].filename;
    }
    for (int i = 0; i < n2; i++) {
        int dup = 0;
        for (int j = 0; j < nall; j++) if (strcmp(allnames[j], entries2[i].filename) == 0) { dup = 1; break; }
        if (!dup) allnames[nall++] = entries2[i].filename;
    }
    qsort(allnames, nall, sizeof(char *), cmp_str);

    for (int i = 0; i < nall; i++) {
        const char *name = allnames[i];
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < n1; j++) if (strcmp(entries1[j].filename, name) == 0) { h1 = entries1[j].hash; break; }
        for (int j = 0; j < n2; j++) if (strcmp(entries2[j].filename, name) == 0) { h2 = entries2[j].hash; break; }

        if (h1 && !h2) printf("Removed: %s\n", name);
        else if (!h1 && h2) printf("Added: %s\n", name);
        else if (h1 && h2 && strcmp(h1, h2) != 0) printf("Modified: %s\n", name);
    }

    free(allnames);
    free(entries1);
    free(entries2);
    return 0;
}

static int cmd_checkout(const char *commit_hash) {
    char commitpath[512];
    snprintf(commitpath, sizeof(commitpath), "%s/%s", COMMITS_DIR, commit_hash);
    if (!file_exists(commitpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    commit_file_entry *entries = NULL;
    int n = parse_commit_files(commit_hash, &entries, NULL, NULL, NULL);
    if (n < 0) {
        printf("Invalid commit\n");
        free(entries);
        return 1;
    }

    /* Restore each file from objects */
    for (int i = 0; i < n; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), "%s/%s", OBJECTS_DIR, entries[i].hash);
        size_t len;
        char *data = read_file(objpath, &len);
        if (data) {
            write_file(entries[i].filename, data, len);
            free(data);
        }
    }

    /* Update HEAD */
    write_file(HEAD_FILE, commit_hash, strlen(commit_hash));
    /* Clear index */
    write_file(INDEX_FILE, "", 0);

    printf("Checked out %s\n", commit_hash);

    free(entries);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char commitpath[512];
    snprintf(commitpath, sizeof(commitpath), "%s/%s", COMMITS_DIR, commit_hash);
    if (!file_exists(commitpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Update HEAD */
    write_file(HEAD_FILE, commit_hash, strlen(commit_hash));
    /* Clear index */
    write_file(INDEX_FILE, "", 0);

    printf("Reset to %s\n", commit_hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    char **lines;
    int count = read_index(&lines);
    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) { found = i; break; }
    }
    if (found < 0) {
        printf("File not in index\n");
        for (int i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 1;
    }

    /* Rewrite index without the file */
    FILE *f = fopen(INDEX_FILE, "w");
    for (int i = 0; i < count; i++) {
        if (i != found) fprintf(f, "%s\n", lines[i]);
        free(lines[i]);
    }
    fclose(f);
    free(lines);
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char commitpath[512];
    snprintf(commitpath, sizeof(commitpath), "%s/%s", COMMITS_DIR, commit_hash);
    if (!file_exists(commitpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    commit_file_entry *entries = NULL;
    char timestamp[64] = "";
    char message[1024] = "";
    int n = parse_commit_files(commit_hash, &entries, NULL, timestamp, message);
    if (n < 0) {
        printf("Invalid commit\n");
        free(entries);
        return 1;
    }

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");
    for (int i = 0; i < n; i++) {
        printf("  %s %s\n", entries[i].filename, entries[i].hash);
    }

    free(entries);
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
    } else if (strcmp(argv[1], "status") == 0) {
        return cmd_status();
    } else if (strcmp(argv[1], "log") == 0) {
        return cmd_log();
    } else if (strcmp(argv[1], "diff") == 0) {
        if (argc < 4) { fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n"); return 1; }
        return cmd_diff(argv[2], argv[3]);
    } else if (strcmp(argv[1], "checkout") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit checkout <commit_hash>\n"); return 1; }
        return cmd_checkout(argv[2]);
    } else if (strcmp(argv[1], "reset") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit reset <commit_hash>\n"); return 1; }
        return cmd_reset(argv[2]);
    } else if (strcmp(argv[1], "rm") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit rm <file>\n"); return 1; }
        return cmd_rm(argv[2]);
    } else if (strcmp(argv[1], "show") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit show <commit_hash>\n"); return 1; }
        return cmd_show(argv[2]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
        return 1;
    }
}
