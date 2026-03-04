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
    if (sz > 0) {
        size_t r = fread(buf, 1, sz, f);
        (void)r;
    }
    buf[sz] = 0;
    fclose(f);
    *out_len = (size_t)sz;
    return buf;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror("fopen"); exit(1); }
    fwrite(data, 1, len, f);
    fclose(f);
}

static int read_lines(const char *path, char lines[][MAX_PATH], int max) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int count = 0;
    while (count < max && fgets(lines[count], MAX_PATH, f)) {
        /* strip newline */
        size_t l = strlen(lines[count]);
        while (l > 0 && (lines[count][l-1] == '\n' || lines[count][l-1] == '\r'))
            lines[count][--l] = 0;
        if (l > 0) count++;
    }
    fclose(f);
    return count;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

/* ---- commands ---- */

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

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }
    /* hash file content */
    size_t len;
    unsigned char *data = read_file(filename, &len);
    char hash[17];
    minihash(data, len, hash);

    /* write object */
    char objpath[MAX_PATH];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, (char *)data, len);
    free(data);

    /* update index: add filename if not present */
    char lines[MAX_FILES][MAX_PATH];
    int count = read_lines(".minigit/index", lines, MAX_FILES);
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) return 0;
    }
    FILE *f = fopen(".minigit/index", "a");
    fprintf(f, "%s\n", filename);
    fclose(f);
    return 0;
}

static int cmd_commit(const char *message) {
    /* read index */
    char lines[MAX_FILES][MAX_PATH];
    int count = read_lines(".minigit/index", lines, MAX_FILES);
    if (count == 0) {
        printf("Nothing to commit\n");
        return 1;
    }

    /* read HEAD */
    char head[MAX_PATH] = "";
    {
        size_t hlen;
        unsigned char *hdata = read_file(".minigit/HEAD", &hlen);
        if (hdata) {
            /* trim */
            while (hlen > 0 && (hdata[hlen-1] == '\n' || hdata[hlen-1] == '\r'))
                hlen--;
            if (hlen > 0 && hlen < sizeof(head)) {
                memcpy(head, hdata, hlen);
                head[hlen] = 0;
            }
            free(hdata);
        }
    }

    const char *parent = (head[0] ? head : "NONE");

    /* sort filenames */
    char *sorted[MAX_FILES];
    for (int i = 0; i < count; i++) sorted[i] = lines[i];
    qsort(sorted, count, sizeof(char *), cmp_str);

    /* build commit content */
    char commit_buf[65536];
    int pos = 0;
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "parent: %s\n", parent);
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "timestamp: %ld\n", (long)time(NULL));
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "message: %s\n", message);
    pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "files:\n");

    for (int i = 0; i < count; i++) {
        /* hash the file */
        size_t flen;
        unsigned char *fdata = read_file(sorted[i], &flen);
        if (!fdata) {
            /* file may have been deleted; read from objects - skip for now, use empty */
            pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "%s 0000000000000000\n", sorted[i]);
            continue;
        }
        char fhash[17];
        minihash(fdata, flen, fhash);
        free(fdata);
        pos += snprintf(commit_buf + pos, sizeof(commit_buf) - pos, "%s %s\n", sorted[i], fhash);
    }

    /* hash commit */
    char commit_hash[17];
    minihash((unsigned char *)commit_buf, pos, commit_hash);

    /* write commit file */
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, commit_buf, pos);

    /* update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_log(void) {
    /* read HEAD */
    size_t hlen;
    unsigned char *hdata = read_file(".minigit/HEAD", &hlen);
    if (!hdata || hlen == 0) {
        printf("No commits\n");
        free(hdata);
        return 0;
    }
    /* trim */
    while (hlen > 0 && (hdata[hlen-1] == '\n' || hdata[hlen-1] == '\r'))
        hlen--;
    if (hlen == 0) {
        printf("No commits\n");
        free(hdata);
        return 0;
    }

    char current[MAX_PATH];
    memcpy(current, hdata, hlen);
    current[hlen] = 0;
    free(hdata);

    int first = 1;
    while (current[0]) {
        char cpath[MAX_PATH];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        size_t clen;
        unsigned char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* parse commit */
        char *text = (char *)cdata;
        char parent[MAX_PATH] = "";
        char timestamp[MAX_PATH] = "";
        char message[MAX_PATH] = "";

        char *line = strtok(text, "\n");
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

        free(cdata);

        if (strcmp(parent, "NONE") == 0 || parent[0] == 0)
            break;
        strncpy(current, parent, sizeof(current) - 1);
        current[sizeof(current) - 1] = 0;
    }
    return 0;
}

static int cmd_status(void) {
    char lines[MAX_FILES][MAX_PATH];
    int count = read_lines(".minigit/index", lines, MAX_FILES);
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

/* Parse commit file: extract parent, timestamp, message, and file entries */
typedef struct {
    char parent[MAX_PATH];
    char timestamp[MAX_PATH];
    char message[MAX_PATH];
    char filenames[MAX_FILES][MAX_PATH];
    char hashes[MAX_FILES][17];
    int file_count;
} CommitInfo;

static int parse_commit(const char *hash, CommitInfo *info) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);
    size_t clen;
    unsigned char *cdata = read_file(cpath, &clen);
    if (!cdata) return -1;

    memset(info, 0, sizeof(*info));

    char *text = (char *)cdata;
    int in_files = 0;

    char *line = strtok(text, "\n");
    while (line) {
        if (strncmp(line, "parent: ", 8) == 0) {
            strncpy(info->parent, line + 8, sizeof(info->parent) - 1);
        } else if (strncmp(line, "timestamp: ", 11) == 0) {
            strncpy(info->timestamp, line + 11, sizeof(info->timestamp) - 1);
        } else if (strncmp(line, "message: ", 9) == 0) {
            strncpy(info->message, line + 9, sizeof(info->message) - 1);
        } else if (strcmp(line, "files:") == 0) {
            in_files = 1;
        } else if (in_files && info->file_count < MAX_FILES) {
            /* format: filename hash */
            char *sp = strchr(line, ' ');
            if (sp) {
                *sp = 0;
                strncpy(info->filenames[info->file_count], line, MAX_PATH - 1);
                strncpy(info->hashes[info->file_count], sp + 1, 16);
                info->hashes[info->file_count][16] = 0;
                info->file_count++;
            }
        }
        line = strtok(NULL, "\n");
    }

    free(cdata);
    return 0;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    CommitInfo c1, c2;
    if (parse_commit(hash1, &c1) != 0 || parse_commit(hash2, &c2) != 0) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Collect all unique filenames */
    static char allfiles[MAX_FILES * 2][MAX_PATH];
    int total = 0;
    for (int i = 0; i < c1.file_count; i++) {
        strncpy(allfiles[total++], c1.filenames[i], MAX_PATH - 1);
    }
    for (int i = 0; i < c2.file_count; i++) {
        int found = 0;
        for (int j = 0; j < total; j++) {
            if (strcmp(allfiles[j], c2.filenames[i]) == 0) { found = 1; break; }
        }
        if (!found) strncpy(allfiles[total++], c2.filenames[i], MAX_PATH - 1);
    }

    /* Sort */
    char *sorted[MAX_FILES * 2];
    for (int i = 0; i < total; i++) sorted[i] = allfiles[i];
    qsort(sorted, total, sizeof(char *), cmp_str);

    for (int i = 0; i < total; i++) {
        const char *fname = sorted[i];
        /* find in c1 and c2 */
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < c1.file_count; j++) {
            if (strcmp(c1.filenames[j], fname) == 0) { h1 = c1.hashes[j]; break; }
        }
        for (int j = 0; j < c2.file_count; j++) {
            if (strcmp(c2.filenames[j], fname) == 0) { h2 = c2.hashes[j]; break; }
        }

        if (!h1 && h2) {
            printf("Added: %s\n", fname);
        } else if (h1 && !h2) {
            printf("Removed: %s\n", fname);
        } else if (h1 && h2 && strcmp(h1, h2) != 0) {
            printf("Modified: %s\n", fname);
        }
    }
    return 0;
}

static int cmd_checkout(const char *hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    CommitInfo info;
    if (parse_commit(hash, &info) != 0) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Restore files from blobs */
    for (int i = 0; i < info.file_count; i++) {
        char objpath[MAX_PATH];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", info.hashes[i]);
        size_t len;
        unsigned char *data = read_file(objpath, &len);
        if (data) {
            write_file(info.filenames[i], (char *)data, len);
            free(data);
        }
    }

    /* Update HEAD */
    write_file(".minigit/HEAD", hash, strlen(hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Checked out %s\n", hash);
    return 0;
}

static int cmd_reset(const char *hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    /* Update HEAD */
    write_file(".minigit/HEAD", hash, strlen(hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Reset to %s\n", hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    char lines[MAX_FILES][MAX_PATH];
    int count = read_lines(".minigit/index", lines, MAX_FILES);

    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) { found = i; break; }
    }

    if (found < 0) {
        printf("File not in index\n");
        return 1;
    }

    /* Rewrite index without the file */
    FILE *f = fopen(".minigit/index", "w");
    for (int i = 0; i < count; i++) {
        if (i != found) {
            fprintf(f, "%s\n", lines[i]);
        }
    }
    fclose(f);
    return 0;
}

static int cmd_show(const char *hash) {
    char cpath[MAX_PATH];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    CommitInfo info;
    if (parse_commit(hash, &info) != 0) {
        printf("Invalid commit\n");
        return 1;
    }

    printf("commit %s\n", hash);
    printf("Date: %s\n", info.timestamp);
    printf("Message: %s\n", info.message);
    printf("Files:\n");

    /* Sort filenames */
    char *sorted[MAX_FILES];
    for (int i = 0; i < info.file_count; i++) sorted[i] = info.filenames[i];
    qsort(sorted, info.file_count, sizeof(char *), cmp_str);

    for (int i = 0; i < info.file_count; i++) {
        /* find hash for this filename */
        for (int j = 0; j < info.file_count; j++) {
            if (strcmp(info.filenames[j], sorted[i]) == 0) {
                printf("  %s %s\n", sorted[i], info.hashes[j]);
                break;
            }
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command>\n");
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
    } else if (strcmp(cmd, "status") == 0) {
        return cmd_status();
    } else if (strcmp(cmd, "diff") == 0) {
        if (argc < 4) { fprintf(stderr, "Usage: minigit diff <commit1> <commit2>\n"); return 1; }
        return cmd_diff(argv[2], argv[3]);
    } else if (strcmp(cmd, "checkout") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit checkout <commit_hash>\n"); return 1; }
        return cmd_checkout(argv[2]);
    } else if (strcmp(cmd, "reset") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit reset <commit_hash>\n"); return 1; }
        return cmd_reset(argv[2]);
    } else if (strcmp(cmd, "rm") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit rm <file>\n"); return 1; }
        return cmd_rm(argv[2]);
    } else if (strcmp(cmd, "show") == 0) {
        if (argc < 3) { fprintf(stderr, "Usage: minigit show <commit_hash>\n"); return 1; }
        return cmd_show(argv[2]);
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
}
