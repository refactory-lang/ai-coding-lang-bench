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

/* MiniHash: FNV-1a variant, 64-bit, 16-char hex */
static void minihash(const unsigned char *data, size_t len, char out[17]) {
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
    minihash(buf, rd, out);
    free(buf);
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static int is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static void mkdirp(const char *path) {
    mkdir(path, 0755);
}

static char *read_file_text(const char *path, size_t *outlen) {
    FILE *f = fopen(path, "r");
    if (!f) { if (outlen) *outlen = 0; return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    fclose(f);
    if (outlen) *outlen = rd;
    return buf;
}

static unsigned char *read_file_bin(const char *path, size_t *outlen) {
    FILE *f = fopen(path, "rb");
    if (!f) { *outlen = 0; return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(sz > 0 ? sz : 1);
    *outlen = fread(buf, 1, sz, f);
    fclose(f);
    return buf;
}

static void write_file(const char *path, const char *data) {
    FILE *f = fopen(path, "w");
    if (f) { fputs(data, f); fclose(f); }
}

static void copy_file(const char *src, const char *dst) {
    FILE *in = fopen(src, "rb");
    if (!in) return;
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); return; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
        fwrite(buf, 1, n, out);
    fclose(in);
    fclose(out);
}

/* Read index lines into array, return count */
static int read_index(char lines[][256], int max) {
    FILE *f = fopen(".minigit/index", "r");
    if (!f) return 0;
    int count = 0;
    char buf[256];
    while (count < max && fgets(buf, sizeof(buf), f)) {
        /* strip newline */
        size_t len = strlen(buf);
        while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r')) buf[--len] = '\0';
        if (len > 0) {
            strncpy(lines[count], buf, 255);
            lines[count][255] = '\0';
            count++;
        }
    }
    fclose(f);
    return count;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

/* ========== Commands ========== */

static int cmd_init(void) {
    if (is_dir(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdirp(".minigit");
    mkdirp(".minigit/objects");
    mkdirp(".minigit/commits");
    write_file(".minigit/index", "");
    write_file(".minigit/HEAD", "");
    return 0;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }
    /* Hash and store blob */
    char hash[17];
    minihash_file(filename, hash);
    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    if (!file_exists(objpath))
        copy_file(filename, objpath);

    /* Check if already in index */
    char lines[1024][256];
    int count = read_index(lines, 1024);
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0)
            return 0; /* already staged */
    }

    /* Append to index */
    FILE *f = fopen(".minigit/index", "a");
    if (f) { fprintf(f, "%s\n", filename); fclose(f); }
    return 0;
}

static int cmd_commit(const char *message) {
    char lines[1024][256];
    int count = read_index(lines, 1024);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(lines, count, 256, cmp_str);

    /* Read HEAD */
    char *head = read_file_text(".minigit/HEAD", NULL);
    char parent[64] = "NONE";
    if (head) {
        size_t hlen = strlen(head);
        while (hlen > 0 && (head[hlen-1] == '\n' || head[hlen-1] == '\r')) head[--hlen] = '\0';
        if (hlen > 0) strncpy(parent, head, 63);
        parent[63] = '\0';
        free(head);
    }

    /* Get timestamp */
    long ts = (long)time(NULL);

    /* Build commit content */
    /* First pass: compute size needed */
    size_t needed = 0;
    needed += snprintf(NULL, 0, "parent: %s\ntimestamp: %ld\nmessage: %s\nfiles:\n", parent, ts, message);
    for (int i = 0; i < count; i++) {
        /* Hash the file content for blob hash */
        char fhash[17];
        minihash_file(lines[i], fhash);
        needed += snprintf(NULL, 0, "%s %s\n", lines[i], fhash);
    }

    char *content = malloc(needed + 1);
    int pos = sprintf(content, "parent: %s\ntimestamp: %ld\nmessage: %s\nfiles:\n", parent, ts, message);
    for (int i = 0; i < count; i++) {
        char fhash[17];
        minihash_file(lines[i], fhash);
        pos += sprintf(content + pos, "%s %s\n", lines[i], fhash);
    }

    /* Hash commit content */
    char commit_hash[17];
    minihash((unsigned char *)content, pos, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content);
    free(content);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash);

    /* Clear index */
    write_file(".minigit/index", "");

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_status(void) {
    char lines[1024][256];
    int count = read_index(lines, 1024);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++)
            printf("%s\n", lines[i]);
    }
    return 0;
}

static int cmd_log(void) {
    char *head = read_file_text(".minigit/HEAD", NULL);
    if (!head || strlen(head) == 0 || head[0] == '\n') {
        printf("No commits\n");
        free(head);
        return 0;
    }
    /* Trim */
    size_t hlen = strlen(head);
    while (hlen > 0 && (head[hlen-1] == '\n' || head[hlen-1] == '\r')) head[--hlen] = '\0';
    if (hlen == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[64];
    strncpy(current, head, 63);
    current[63] = '\0';
    free(head);

    while (1) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        char *content = read_file_text(cpath, NULL);
        if (!content) break;

        /* Parse parent, timestamp, message */
        char par[64] = "NONE";
        char ts[64] = "";
        char msg[1024] = "";

        char *line = strtok(content, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0)
                strncpy(par, line + 8, 63);
            else if (strncmp(line, "timestamp: ", 11) == 0)
                strncpy(ts, line + 11, 63);
            else if (strncmp(line, "message: ", 9) == 0)
                strncpy(msg, line + 9, 1023);
            line = strtok(NULL, "\n");
        }

        printf("commit %s\nDate: %s\nMessage: %s\n\n", current, ts, msg);
        free(content);

        if (strcmp(par, "NONE") == 0) break;
        strncpy(current, par, 63);
        current[63] = '\0';
    }

    return 0;
}

/* Parse commit file: extract files section into parallel arrays */
static int parse_commit_files(const char *commit_hash, char fnames[][256], char fhashes[][17], int max) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    char *content = read_file_text(cpath, NULL);
    if (!content) return -1;

    int count = 0;
    int in_files = 0;
    char *saveptr = NULL;
    char *line = strtok_r(content, "\n", &saveptr);
    while (line) {
        if (in_files) {
            if (count < max) {
                char name[256], hash[17];
                if (sscanf(line, "%255s %16s", name, hash) == 2) {
                    strncpy(fnames[count], name, 255);
                    fnames[count][255] = '\0';
                    strncpy(fhashes[count], hash, 16);
                    fhashes[count][16] = '\0';
                    count++;
                }
            }
        } else if (strcmp(line, "files:") == 0) {
            in_files = 1;
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }
    free(content);
    return count;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char f1[1024][256], h1[1024][17];
    char f2[1024][256], h2[1024][17];

    int c1 = parse_commit_files(hash1, f1, h1, 1024);
    if (c1 < 0) { printf("Invalid commit\n"); return 1; }
    int c2 = parse_commit_files(hash2, f2, h2, 1024);
    if (c2 < 0) { printf("Invalid commit\n"); return 1; }

    /* Collect all filenames, sorted */
    char all[2048][256];
    int acount = 0;
    for (int i = 0; i < c1; i++) { strncpy(all[acount++], f1[i], 255); all[acount-1][255] = '\0'; }
    for (int i = 0; i < c2; i++) {
        int found = 0;
        for (int j = 0; j < acount; j++) if (strcmp(all[j], f2[i]) == 0) { found = 1; break; }
        if (!found) { strncpy(all[acount++], f2[i], 255); all[acount-1][255] = '\0'; }
    }
    qsort(all, acount, 256, cmp_str);

    for (int i = 0; i < acount; i++) {
        char *in1_hash = NULL, *in2_hash = NULL;
        for (int j = 0; j < c1; j++) if (strcmp(f1[j], all[i]) == 0) { in1_hash = h1[j]; break; }
        for (int j = 0; j < c2; j++) if (strcmp(f2[j], all[i]) == 0) { in2_hash = h2[j]; break; }

        if (!in1_hash && in2_hash)
            printf("Added: %s\n", all[i]);
        else if (in1_hash && !in2_hash)
            printf("Removed: %s\n", all[i]);
        else if (in1_hash && in2_hash && strcmp(in1_hash, in2_hash) != 0)
            printf("Modified: %s\n", all[i]);
    }
    return 0;
}

static int cmd_checkout(const char *commit_hash) {
    char fnames[1024][256], fhashes[1024][17];
    int count = parse_commit_files(commit_hash, fnames, fhashes, 1024);
    if (count < 0) { printf("Invalid commit\n"); return 1; }

    for (int i = 0; i < count; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", fhashes[i]);
        size_t len;
        unsigned char *data = read_file_bin(objpath, &len);
        if (data) {
            FILE *f = fopen(fnames[i], "wb");
            if (f) { fwrite(data, 1, len, f); fclose(f); }
            free(data);
        }
    }

    write_file(".minigit/HEAD", commit_hash);
    write_file(".minigit/index", "");
    printf("Checked out %s\n", commit_hash);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }
    write_file(".minigit/HEAD", commit_hash);
    write_file(".minigit/index", "");
    printf("Reset to %s\n", commit_hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    char lines[1024][256];
    int count = read_index(lines, 1024);
    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) { found = i; break; }
    }
    if (found < 0) {
        printf("File not in index\n");
        return 1;
    }
    FILE *f = fopen(".minigit/index", "w");
    if (f) {
        for (int i = 0; i < count; i++) {
            if (i != found) fprintf(f, "%s\n", lines[i]);
        }
        fclose(f);
    }
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    char *content = read_file_text(cpath, NULL);
    if (!content) { printf("Invalid commit\n"); return 1; }

    char ts[64] = "", msg[1024] = "";
    char fnames[1024][256], fhashes[1024][17];
    int fcount = 0, in_files = 0;
    char *saveptr = NULL;
    char *line = strtok_r(content, "\n", &saveptr);
    while (line) {
        if (in_files) {
            char name[256], hash[17];
            if (sscanf(line, "%255s %16s", name, hash) == 2 && fcount < 1024) {
                strncpy(fnames[fcount], name, 255); fnames[fcount][255] = '\0';
                strncpy(fhashes[fcount], hash, 16); fhashes[fcount][16] = '\0';
                fcount++;
            }
        } else if (strncmp(line, "timestamp: ", 11) == 0)
            strncpy(ts, line + 11, 63);
        else if (strncmp(line, "message: ", 9) == 0)
            strncpy(msg, line + 9, 1023);
        else if (strcmp(line, "files:") == 0)
            in_files = 1;
        line = strtok_r(NULL, "\n", &saveptr);
    }
    free(content);

    qsort(fnames, fcount, 256, cmp_str);
    /* Re-sort fhashes to match - need paired sort */
    /* Actually need to re-parse or do paired sort. Let me just use paired arrays properly. */
    /* Since files in commit are already sorted, just print as-is from parse */

    /* Re-read to get proper sorted order */
    int count2 = parse_commit_files(commit_hash, fnames, fhashes, 1024);

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", ts);
    printf("Message: %s\n", msg);
    printf("Files:\n");
    /* Sort by filename */
    /* Simple bubble sort on parallel arrays */
    for (int i = 0; i < count2 - 1; i++) {
        for (int j = i + 1; j < count2; j++) {
            if (strcmp(fnames[i], fnames[j]) > 0) {
                char tmp[256]; strncpy(tmp, fnames[i], 255); tmp[255] = '\0';
                strncpy(fnames[i], fnames[j], 255); fnames[i][255] = '\0';
                strncpy(fnames[j], tmp, 255); fnames[j][255] = '\0';
                char th[17]; strncpy(th, fhashes[i], 16); th[16] = '\0';
                strncpy(fhashes[i], fhashes[j], 16); fhashes[i][16] = '\0';
                strncpy(fhashes[j], th, 16); fhashes[j][16] = '\0';
            }
        }
    }
    for (int i = 0; i < count2; i++)
        printf("  %s %s\n", fnames[i], fhashes[i]);

    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command> [args]\n");
        return 1;
    }

    if (strcmp(argv[1], "init") == 0)
        return cmd_init();
    if (strcmp(argv[1], "add") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit add <file>\n"); return 1; }
        return cmd_add(argv[2]);
    }
    if (strcmp(argv[1], "commit") == 0) {
        if (argc < 4 || strcmp(argv[2], "-m") != 0) {
            fprintf(stderr, "Usage: minigit commit -m \"<message>\"\n");
            return 1;
        }
        return cmd_commit(argv[3]);
    }
    if (strcmp(argv[1], "status") == 0)
        return cmd_status();
    if (strcmp(argv[1], "log") == 0)
        return cmd_log();
    if (strcmp(argv[1], "diff") == 0) {
        if (argc < 4) { fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n"); return 1; }
        return cmd_diff(argv[2], argv[3]);
    }
    if (strcmp(argv[1], "checkout") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit checkout <commit_hash>\n"); return 1; }
        return cmd_checkout(argv[2]);
    }
    if (strcmp(argv[1], "reset") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit reset <commit_hash>\n"); return 1; }
        return cmd_reset(argv[2]);
    }
    if (strcmp(argv[1], "rm") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit rm <file>\n"); return 1; }
        return cmd_rm(argv[2]);
    }
    if (strcmp(argv[1], "show") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit show <commit_hash>\n"); return 1; }
        return cmd_show(argv[2]);
    }

    fprintf(stderr, "Unknown command: %s\n", argv[1]);
    return 1;
}
