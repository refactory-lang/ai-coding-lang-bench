#define _GNU_SOURCE
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

static char *read_file_str(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    fclose(f);
    return buf;
}

static void write_file_str(const char *path, const char *content) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    fputs(content, f);
    fclose(f);
}

static void copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return; }
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
        fwrite(buf, 1, n, out);
    fclose(in);
    fclose(out);
}

/* Read index file, return array of filenames and count */
static int read_index(char files[][MAX_PATH], int max) {
    FILE *f = fopen(".minigit/index", "r");
    if (!f) return 0;
    int count = 0;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f) && count < max) {
        /* strip newline */
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';
        if (len > 0) {
            strncpy(files[count], line, MAX_PATH - 1);
            files[count][MAX_PATH - 1] = '\0';
            count++;
        }
    }
    fclose(f);
    return count;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

/* Parse commit file: extract files section into parallel arrays */
static int parse_commit_files(const char *commit_hash, char fnames[][MAX_PATH], char fhashes[][17]) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    char *content = read_file_str(cpath);
    if (!content) return -1;

    int count = 0;
    int in_files = 0;
    char *saveptr = NULL;
    char *line = strtok_r(content, "\n", &saveptr);
    while (line) {
        if (in_files) {
            char name[MAX_PATH], hash[17];
            if (sscanf(line, "%s %16s", name, hash) == 2 && count < MAX_FILES) {
                strncpy(fnames[count], name, MAX_PATH - 1);
                strncpy(fhashes[count], hash, 16);
                fhashes[count][16] = '\0';
                count++;
            }
        } else if (strcmp(line, "files:") == 0) {
            in_files = 1;
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }
    free(content);
    return count;
}

/* ===== COMMANDS ===== */

static int cmd_init(void) {
    if (dir_exists(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdirp(".minigit");
    mkdirp(".minigit/objects");
    mkdirp(".minigit/commits");
    write_file_str(".minigit/index", "");
    write_file_str(".minigit/HEAD", "");
    return 0;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }
    /* Compute hash and store blob */
    char hash[17];
    minihash_file(filename, hash);

    char objpath[MAX_PATH];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    copy_file(filename, objpath);

    /* Check if already in index */
    char files[MAX_FILES][MAX_PATH];
    int count = read_index(files, MAX_FILES);
    for (int i = 0; i < count; i++) {
        if (strcmp(files[i], filename) == 0)
            return 0; /* already staged */
    }

    /* Append to index */
    FILE *f = fopen(".minigit/index", "a");
    if (f) {
        fprintf(f, "%s\n", filename);
        fclose(f);
    }
    return 0;
}

static int cmd_commit(const char *message) {
    /* Read index */
    char files[MAX_FILES][MAX_PATH];
    int count = read_index(files, MAX_FILES);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(files, count, MAX_PATH, cmp_str);

    /* Get parent */
    char *head = read_file_str(".minigit/HEAD");
    char parent[MAX_PATH] = "NONE";
    if (head) {
        size_t len = strlen(head);
        while (len > 0 && (head[len-1] == '\n' || head[len-1] == '\r'))
            head[--len] = '\0';
        if (len > 0)
            strncpy(parent, head, sizeof(parent) - 1);
        free(head);
    }

    /* Get timestamp */
    long ts = (long)time(NULL);

    /* Build commit content */
    /* First pass: compute size needed */
    size_t needed = 0;
    needed += snprintf(NULL, 0, "parent: %s\n", parent);
    needed += snprintf(NULL, 0, "timestamp: %ld\n", ts);
    needed += snprintf(NULL, 0, "message: %s\n", message);
    needed += snprintf(NULL, 0, "files:\n");
    for (int i = 0; i < count; i++) {
        /* Hash the file content (re-read from working dir) */
        char hash[17];
        minihash_file(files[i], hash);
        needed += snprintf(NULL, 0, "%s %s\n", files[i], hash);
    }

    char *content = malloc(needed + 1);
    char *p = content;
    p += sprintf(p, "parent: %s\n", parent);
    p += sprintf(p, "timestamp: %ld\n", ts);
    p += sprintf(p, "message: %s\n", message);
    p += sprintf(p, "files:\n");
    for (int i = 0; i < count; i++) {
        char hash[17];
        minihash_file(files[i], hash);
        p += sprintf(p, "%s %s\n", files[i], hash);
    }

    /* Hash the commit content */
    char commit_hash[17];
    minihash_bytes((unsigned char *)content, strlen(content), commit_hash);

    /* Write commit file */
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file_str(cpath, content);
    free(content);

    /* Update HEAD */
    write_file_str(".minigit/HEAD", commit_hash);

    /* Clear index */
    write_file_str(".minigit/index", "");

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_log(void) {
    char *head = read_file_str(".minigit/HEAD");
    if (!head || strlen(head) == 0 || head[0] == '\n') {
        printf("No commits\n");
        free(head);
        return 0;
    }
    /* Trim */
    size_t len = strlen(head);
    while (len > 0 && (head[len-1] == '\n' || head[len-1] == '\r'))
        head[--len] = '\0';
    if (len == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[MAX_PATH];
    strncpy(current, head, sizeof(current) - 1);
    free(head);

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[MAX_PATH];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        char *content = read_file_str(cpath);
        if (!content) break;

        /* Parse parent, timestamp, message */
        char parent[MAX_PATH] = "";
        char timestamp[64] = "";
        char message[MAX_LINE] = "";

        char *line = strtok(content, "\n");
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

        free(content);
        strncpy(current, parent, sizeof(current) - 1);
    }

    return 0;
}

static int cmd_status(void) {
    char files[MAX_FILES][MAX_PATH];
    int count = read_index(files, MAX_FILES);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++)
            printf("%s\n", files[i]);
    }
    return 0;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    static char fnames1[MAX_FILES][MAX_PATH], fhashes1[MAX_FILES][17];
    static char fnames2[MAX_FILES][MAX_PATH], fhashes2[MAX_FILES][17];

    int c1 = parse_commit_files(hash1, fnames1, fhashes1);
    if (c1 < 0) { printf("Invalid commit\n"); return 1; }
    int c2 = parse_commit_files(hash2, fnames2, fhashes2);
    if (c2 < 0) { printf("Invalid commit\n"); return 1; }

    /* Collect all unique filenames, sorted */
    static char all[MAX_FILES * 2][MAX_PATH];
    int total = 0;
    for (int i = 0; i < c1; i++) { strncpy(all[total++], fnames1[i], MAX_PATH - 1); }
    for (int i = 0; i < c2; i++) {
        int found = 0;
        for (int j = 0; j < total; j++) {
            if (strcmp(all[j], fnames2[i]) == 0) { found = 1; break; }
        }
        if (!found) strncpy(all[total++], fnames2[i], MAX_PATH - 1);
    }
    qsort(all, total, MAX_PATH, cmp_str);

    for (int i = 0; i < total; i++) {
        /* Find in commit1 */
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < c1; j++) {
            if (strcmp(fnames1[j], all[i]) == 0) { h1 = fhashes1[j]; break; }
        }
        for (int j = 0; j < c2; j++) {
            if (strcmp(fnames2[j], all[i]) == 0) { h2 = fhashes2[j]; break; }
        }
        if (!h1 && h2) printf("Added: %s\n", all[i]);
        else if (h1 && !h2) printf("Removed: %s\n", all[i]);
        else if (h1 && h2 && strcmp(h1, h2) != 0) printf("Modified: %s\n", all[i]);
    }
    return 0;
}

static int cmd_checkout(const char *commit_hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    char fnames[MAX_FILES][MAX_PATH], fhashes[MAX_FILES][17];
    int count = parse_commit_files(commit_hash, fnames, fhashes);

    for (int i = 0; i < count; i++) {
        char objpath[MAX_PATH];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", fhashes[i]);
        copy_file(objpath, fnames[i]);
    }

    write_file_str(".minigit/HEAD", commit_hash);
    write_file_str(".minigit/index", "");

    printf("Checked out %s\n", commit_hash);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    write_file_str(".minigit/HEAD", commit_hash);
    write_file_str(".minigit/index", "");

    printf("Reset to %s\n", commit_hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    char files[MAX_FILES][MAX_PATH];
    int count = read_index(files, MAX_FILES);
    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(files[i], filename) == 0) { found = i; break; }
    }
    if (found < 0) {
        printf("File not in index\n");
        return 1;
    }
    /* Rewrite index without the file */
    FILE *f = fopen(".minigit/index", "w");
    if (f) {
        for (int i = 0; i < count; i++) {
            if (i != found) fprintf(f, "%s\n", files[i]);
        }
        fclose(f);
    }
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    char *content = read_file_str(cpath);
    if (!content) {
        printf("Invalid commit\n");
        return 1;
    }

    char timestamp[64] = "";
    char message[MAX_LINE] = "";
    char fnames[MAX_FILES][MAX_PATH];
    char fhashes[MAX_FILES][17];
    int fcount = 0;
    int in_files = 0;

    char *saveptr = NULL;
    char *line = strtok_r(content, "\n", &saveptr);
    while (line) {
        if (in_files) {
            char name[MAX_PATH], hash[17];
            if (sscanf(line, "%s %16s", name, hash) == 2 && fcount < MAX_FILES) {
                strncpy(fnames[fcount], name, MAX_PATH - 1);
                strncpy(fhashes[fcount], hash, 16);
                fhashes[fcount][16] = '\0';
                fcount++;
            }
        } else if (strncmp(line, "timestamp: ", 11) == 0) {
            strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
        } else if (strncmp(line, "message: ", 9) == 0) {
            strncpy(message, line + 9, sizeof(message) - 1);
        } else if (strcmp(line, "files:") == 0) {
            in_files = 1;
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }
    free(content);

    /* Sort files */
    /* We need to sort fnames and fhashes together */
    for (int i = 0; i < fcount - 1; i++) {
        for (int j = i + 1; j < fcount; j++) {
            if (strcmp(fnames[i], fnames[j]) > 0) {
                char tmp[MAX_PATH];
                strncpy(tmp, fnames[i], MAX_PATH);
                strncpy(fnames[i], fnames[j], MAX_PATH);
                strncpy(fnames[j], tmp, MAX_PATH);
                char tmph[17];
                strncpy(tmph, fhashes[i], 17);
                strncpy(fhashes[i], fhashes[j], 17);
                strncpy(fhashes[j], tmph, 17);
            }
        }
    }

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");
    for (int i = 0; i < fcount; i++) {
        printf("  %s %s\n", fnames[i], fhashes[i]);
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
    } else if (strcmp(cmd, "status") == 0) {
        return cmd_status();
    } else if (strcmp(cmd, "diff") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n");
            return 1;
        }
        return cmd_diff(argv[2], argv[3]);
    } else if (strcmp(cmd, "checkout") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit checkout <commit_hash>\n");
            return 1;
        }
        return cmd_checkout(argv[2]);
    } else if (strcmp(cmd, "reset") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit reset <commit_hash>\n");
            return 1;
        }
        return cmd_reset(argv[2]);
    } else if (strcmp(cmd, "rm") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit rm <file>\n");
            return 1;
        }
        return cmd_rm(argv[2]);
    } else if (strcmp(cmd, "show") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: minigit show <commit_hash>\n");
            return 1;
        }
        return cmd_show(argv[2]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
}
