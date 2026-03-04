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
    if (!f) return;
    fwrite(data, 1, len, f);
    fclose(f);
}

static void write_str(const char *path, const char *s) {
    write_file(path, s, strlen(s));
}

static int cmd_init(void) {
    if (is_dir(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdir_p(".minigit");
    mkdir_p(".minigit/objects");
    mkdir_p(".minigit/commits");
    write_str(".minigit/index", "");
    write_str(".minigit/HEAD", "");
    return 0;
}

/* Read index lines into array, return count */
static int read_index(char lines[][1024], int max) {
    size_t len;
    char *data = read_file(".minigit/index", &len);
    if (!data || len == 0) {
        free(data);
        return 0;
    }
    int count = 0;
    char *p = data;
    while (*p && count < max) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen > 0 && llen < 1024) {
            memcpy(lines[count], p, llen);
            lines[count][llen] = '\0';
            count++;
        }
        if (!nl) break;
        p = nl + 1;
    }
    free(data);
    return count;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    size_t len;
    char *data = read_file(filename, &len);
    if (!data) {
        printf("File not found\n");
        return 1;
    }

    char hash[17];
    minihash((unsigned char *)data, len, hash);

    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, data, len);
    free(data);

    /* Add to index if not present */
    char lines[4096][1024];
    int count = read_index(lines, 4096);
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0)
            return 0;
    }

    FILE *f = fopen(".minigit/index", "a");
    fprintf(f, "%s\n", filename);
    fclose(f);
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

static int cmd_commit(const char *message) {
    char lines[4096][1024];
    int count = read_index(lines, 4096);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(lines, count, sizeof(lines[0]), cmp_str);

    /* Read HEAD */
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    char parent[64] = "NONE";
    if (head && hlen > 0) {
        char *e = head + hlen - 1;
        while (e >= head && (*e == '\n' || *e == '\r' || *e == ' ')) *e-- = '\0';
        if (strlen(head) > 0)
            strncpy(parent, head, sizeof(parent) - 1);
    }
    free(head);

    time_t ts = time(NULL);

    size_t cap = 65536;
    char *content = malloc(cap);
    int pos = 0;

    pos += snprintf(content + pos, cap - pos, "parent: %s\n", parent);
    pos += snprintf(content + pos, cap - pos, "timestamp: %lld\n", (long long)ts);
    pos += snprintf(content + pos, cap - pos, "message: %s\n", message);
    pos += snprintf(content + pos, cap - pos, "files:\n");

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
        pos += snprintf(content + pos, cap - pos, "%s %s\n", lines[i], fhash);
    }

    char commit_hash[17];
    minihash((unsigned char *)content, pos, commit_hash);

    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, content, pos);
    free(content);

    write_str(".minigit/HEAD", commit_hash);
    write_str(".minigit/index", "");

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_status(void) {
    char lines[4096][1024];
    int count = read_index(lines, 4096);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++) {
            printf("%s\n", lines[i]);
        }
    }
    return 0;
}

static int cmd_log(void) {
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    if (!head || hlen == 0 || head[0] == '\0' || head[0] == '\n') {
        printf("No commits\n");
        free(head);
        return 0;
    }
    char *e = head + strlen(head) - 1;
    while (e >= head && (*e == '\n' || *e == '\r' || *e == ' ')) *e-- = '\0';

    if (strlen(head) == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[64];
    strncpy(current, head, sizeof(current) - 1);
    current[63] = '\0';
    free(head);

    int first = 1;
    while (strcmp(current, "NONE") != 0 && strlen(current) > 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);

        size_t clen;
        char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        char parent[64] = "NONE";
        char timestamp[64] = "";
        char message[1024] = "";

        char *line = cdata;
        while (line && *line) {
            char *nl = strchr(line, '\n');
            size_t llen = nl ? (size_t)(nl - line) : strlen(line);
            char tmp[2048];
            if (llen >= sizeof(tmp)) llen = sizeof(tmp) - 1;
            memcpy(tmp, line, llen);
            tmp[llen] = '\0';

            if (strncmp(tmp, "parent: ", 8) == 0)
                strncpy(parent, tmp + 8, sizeof(parent) - 1);
            else if (strncmp(tmp, "timestamp: ", 11) == 0)
                strncpy(timestamp, tmp + 11, sizeof(timestamp) - 1);
            else if (strncmp(tmp, "message: ", 9) == 0)
                strncpy(message, tmp + 9, sizeof(message) - 1);
            else if (strncmp(tmp, "files:", 6) == 0)
                break;

            if (!nl) break;
            line = nl + 1;
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        free(cdata);
        strncpy(current, parent, sizeof(current) - 1);
    }

    return 0;
}

/* Parse files section of a commit into parallel arrays. Returns file count. */
static int parse_commit_files(const char *cdata, char fnames[][1024], char fhashes[][17], int max) {
    /* Find "files:\n" */
    const char *fp = strstr(cdata, "files:\n");
    if (!fp) return 0;
    fp += 7; /* skip "files:\n" */

    int count = 0;
    while (*fp && count < max) {
        const char *nl = strchr(fp, '\n');
        size_t llen = nl ? (size_t)(nl - fp) : strlen(fp);
        if (llen == 0) break;

        char tmp[2048];
        if (llen >= sizeof(tmp)) llen = sizeof(tmp) - 1;
        memcpy(tmp, fp, llen);
        tmp[llen] = '\0';

        /* Parse "filename hash" */
        char *space = strrchr(tmp, ' ');
        if (space) {
            *space = '\0';
            strncpy(fnames[count], tmp, 1023);
            fnames[count][1023] = '\0';
            strncpy(fhashes[count], space + 1, 16);
            fhashes[count][16] = '\0';
            count++;
        }

        if (!nl) break;
        fp = nl + 1;
    }
    return count;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char p1[512], p2[512];
    snprintf(p1, sizeof(p1), ".minigit/commits/%s", hash1);
    snprintf(p2, sizeof(p2), ".minigit/commits/%s", hash2);

    if (!file_exists(p1) || !file_exists(p2)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t len1, len2;
    char *c1 = read_file(p1, &len1);
    char *c2 = read_file(p2, &len2);

    static char fn1[256][1024], fh1[256][17];
    static char fn2[256][1024], fh2[256][17];
    int cnt1 = parse_commit_files(c1, fn1, fh1, 256);
    int cnt2 = parse_commit_files(c2, fn2, fh2, 256);
    free(c1);
    free(c2);

    /* Collect all unique filenames, sorted */
    static char all[512][1024];
    int total = 0;
    for (int i = 0; i < cnt1; i++) {
        int found = 0;
        for (int j = 0; j < total; j++)
            if (strcmp(all[j], fn1[i]) == 0) { found = 1; break; }
        if (!found) strcpy(all[total++], fn1[i]);
    }
    for (int i = 0; i < cnt2; i++) {
        int found = 0;
        for (int j = 0; j < total; j++)
            if (strcmp(all[j], fn2[i]) == 0) { found = 1; break; }
        if (!found) strcpy(all[total++], fn2[i]);
    }
    qsort(all, total, sizeof(all[0]), cmp_str);

    for (int i = 0; i < total; i++) {
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < cnt1; j++)
            if (strcmp(fn1[j], all[i]) == 0) { h1 = fh1[j]; break; }
        for (int j = 0; j < cnt2; j++)
            if (strcmp(fn2[j], all[i]) == 0) { h2 = fh2[j]; break; }

        if (!h1 && h2) printf("Added: %s\n", all[i]);
        else if (h1 && !h2) printf("Removed: %s\n", all[i]);
        else if (h1 && h2 && strcmp(h1, h2) != 0) printf("Modified: %s\n", all[i]);
    }

    return 0;
}

static int cmd_checkout(const char *hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);

    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t clen;
    char *cdata = read_file(cpath, &clen);

    char fnames[4096][1024], fhashes[4096][17];
    int count = parse_commit_files(cdata, fnames, fhashes, 4096);
    free(cdata);

    /* Restore each file from objects */
    for (int i = 0; i < count; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", fhashes[i]);
        size_t olen;
        char *odata = read_file(objpath, &olen);
        if (odata) {
            write_file(fnames[i], odata, olen);
            free(odata);
        }
    }

    /* Update HEAD */
    write_str(".minigit/HEAD", hash);
    /* Clear index */
    write_str(".minigit/index", "");

    printf("Checked out %s\n", hash);
    return 0;
}

static int cmd_reset(const char *hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);

    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Update HEAD */
    write_str(".minigit/HEAD", hash);
    /* Clear index */
    write_str(".minigit/index", "");

    printf("Reset to %s\n", hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    char lines[4096][1024];
    int count = read_index(lines, 4096);

    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) {
            found = i;
            break;
        }
    }

    if (found < 0) {
        printf("File not in index\n");
        return 1;
    }

    /* Rewrite index without the removed file */
    FILE *f = fopen(".minigit/index", "w");
    for (int i = 0; i < count; i++) {
        if (i != found)
            fprintf(f, "%s\n", lines[i]);
    }
    fclose(f);
    return 0;
}

static int cmd_show(const char *hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);

    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t clen;
    char *cdata = read_file(cpath, &clen);

    char timestamp[64] = "";
    char message[1024] = "";

    char *line = cdata;
    while (line && *line) {
        char *nl = strchr(line, '\n');
        size_t llen = nl ? (size_t)(nl - line) : strlen(line);
        char tmp[2048];
        if (llen >= sizeof(tmp)) llen = sizeof(tmp) - 1;
        memcpy(tmp, line, llen);
        tmp[llen] = '\0';

        if (strncmp(tmp, "timestamp: ", 11) == 0)
            strncpy(timestamp, tmp + 11, sizeof(timestamp) - 1);
        else if (strncmp(tmp, "message: ", 9) == 0)
            strncpy(message, tmp + 9, sizeof(message) - 1);
        else if (strncmp(tmp, "files:", 6) == 0)
            break;

        if (!nl) break;
        line = nl + 1;
    }

    char fnames[4096][1024], fhashes[4096][17];
    int fcount = parse_commit_files(cdata, fnames, fhashes, 4096);
    free(cdata);

    /* Sort files */
    /* Files are already sorted from commit, but sort to be safe */
    /* Need to sort fnames and fhashes together */
    for (int i = 0; i < fcount - 1; i++) {
        for (int j = i + 1; j < fcount; j++) {
            if (strcmp(fnames[i], fnames[j]) > 0) {
                char tmp[1024];
                strcpy(tmp, fnames[i]); strcpy(fnames[i], fnames[j]); strcpy(fnames[j], tmp);
                char th[17];
                strcpy(th, fhashes[i]); strcpy(fhashes[i], fhashes[j]); strcpy(fhashes[j], th);
            }
        }
    }

    printf("commit %s\n", hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");
    for (int i = 0; i < fcount; i++) {
        printf("  %s %s\n", fnames[i], fhashes[i]);
    }

    return 0;
}

int main(int argc, char **argv) {
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
            fprintf(stderr, "Usage: minigit commit -m \"<message>\"\n"); return 1;
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
