#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <unistd.h>

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

static int write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(data, 1, len, f);
    fclose(f);
    return 0;
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

/* Read index file, return array of lines. Caller frees each line and the array. */
static char **read_index(int *count) {
    *count = 0;
    size_t len;
    char *data = read_file(".minigit/index", &len);
    if (!data || len == 0) {
        free(data);
        return NULL;
    }
    /* Count lines */
    int cap = 64;
    char **lines = malloc(cap * sizeof(char*));
    char *p = data;
    while (*p) {
        char *nl = strchr(p, '\n');
        size_t llen = nl ? (size_t)(nl - p) : strlen(p);
        if (llen == 0) { if (nl) { p = nl + 1; continue; } else break; }
        if (*count >= cap) { cap *= 2; lines = realloc(lines, cap * sizeof(char*)); }
        lines[*count] = strndup(p, llen);
        (*count)++;
        p += llen;
        if (*p == '\n') p++;
    }
    free(data);
    return lines;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char**)a, *(const char**)b);
}

static int cmd_init(void) {
    if (dir_exists(".minigit")) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdirp(".minigit");
    mkdirp(".minigit/objects");
    mkdirp(".minigit/commits");
    write_file(".minigit/index", "", 0);
    write_file(".minigit/HEAD", "", 0);
    return 0;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }
    size_t len;
    char *data = read_file(filename, &len);
    char hash[17];
    minihash((unsigned char*)data, len, hash);

    /* Write object */
    char objpath[512];
    snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hash);
    write_file(objpath, data, len);
    free(data);

    /* Update index: add filename if not present */
    int count;
    char **lines = read_index(&count);
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) {
            for (int j = 0; j < count; j++) free(lines[j]);
            free(lines);
            return 0;
        }
    }
    /* Append */
    FILE *f = fopen(".minigit/index", "a");
    fprintf(f, "%s\n", filename);
    fclose(f);
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
    qsort(lines, count, sizeof(char*), cmp_str);

    /* Read HEAD */
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    char parent[64] = "NONE";
    if (head && hlen > 0) {
        /* trim whitespace */
        char *h = head;
        while (*h && *h != '\n' && *h != '\r') h++;
        *h = '\0';
        if (strlen(head) > 0) strncpy(parent, head, sizeof(parent)-1);
    }
    free(head);

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
        /* Hash the current file content */
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char*)fdata, flen, fhash);
            free(fdata);
        } else {
            /* File might have been deleted; use empty hash */
            minihash((unsigned char*)"", 0, fhash);
        }
        needed += snprintf(NULL, 0, "%s %s\n", lines[i], fhash);
    }

    char *commit_content = malloc(needed + 1);
    char *p = commit_content;
    p += sprintf(p, "parent: %s\n", parent);
    p += sprintf(p, "timestamp: %ld\n", ts);
    p += sprintf(p, "message: %s\n", message);
    p += sprintf(p, "files:\n");
    for (int i = 0; i < count; i++) {
        size_t flen;
        char *fdata = read_file(lines[i], &flen);
        char fhash[17];
        if (fdata) {
            minihash((unsigned char*)fdata, flen, fhash);
            free(fdata);
        } else {
            minihash((unsigned char*)"", 0, fhash);
        }
        p += sprintf(p, "%s %s\n", lines[i], fhash);
    }

    size_t commit_len = p - commit_content;

    /* Hash commit */
    char commit_hash[17];
    minihash((unsigned char*)commit_content, commit_len, commit_hash);

    /* Write commit file */
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    write_file(cpath, commit_content, commit_len);

    /* Update HEAD */
    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));

    /* Clear index */
    write_file(".minigit/index", "", 0);

    printf("Committed %s\n", commit_hash);

    free(commit_content);
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_status(void) {
    int count;
    char **lines = read_index(&count);
    printf("Staged files:\n");
    if (count == 0) {
        printf("(none)\n");
    } else {
        for (int i = 0; i < count; i++) {
            printf("%s\n", lines[i]);
        }
    }
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

/* Parse a commit file and extract files section into parallel arrays */
static int parse_commit_files(const char *commit_hash, char ***out_names, char ***out_hashes, int *out_count) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    size_t clen;
    char *cdata = read_file(cpath, &clen);
    if (!cdata) return -1;

    *out_count = 0;
    int cap = 64;
    *out_names = malloc(cap * sizeof(char*));
    *out_hashes = malloc(cap * sizeof(char*));

    int in_files = 0;
    char *saveptr = NULL;
    char *line = strtok_r(cdata, "\n", &saveptr);
    while (line) {
        if (strcmp(line, "files:") == 0) {
            in_files = 1;
        } else if (in_files) {
            char *sp = strchr(line, ' ');
            if (sp) {
                if (*out_count >= cap) {
                    cap *= 2;
                    *out_names = realloc(*out_names, cap * sizeof(char*));
                    *out_hashes = realloc(*out_hashes, cap * sizeof(char*));
                }
                (*out_names)[*out_count] = strndup(line, sp - line);
                (*out_hashes)[*out_count] = strdup(sp + 1);
                (*out_count)++;
            }
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }
    free(cdata);
    return 0;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char **names1, **hashes1, **names2, **hashes2;
    int count1, count2;

    if (parse_commit_files(hash1, &names1, &hashes1, &count1) != 0) {
        printf("Invalid commit\n");
        return 1;
    }
    if (parse_commit_files(hash2, &names2, &hashes2, &count2) != 0) {
        printf("Invalid commit\n");
        for (int i = 0; i < count1; i++) { free(names1[i]); free(hashes1[i]); }
        free(names1); free(hashes1);
        return 1;
    }

    /* Collect all filenames */
    int allcap = count1 + count2;
    char **allnames = malloc(allcap * sizeof(char*));
    int allcount = 0;

    for (int i = 0; i < count1; i++) {
        int dup = 0;
        for (int j = 0; j < allcount; j++) {
            if (strcmp(allnames[j], names1[i]) == 0) { dup = 1; break; }
        }
        if (!dup) allnames[allcount++] = names1[i];
    }
    for (int i = 0; i < count2; i++) {
        int dup = 0;
        for (int j = 0; j < allcount; j++) {
            if (strcmp(allnames[j], names2[i]) == 0) { dup = 1; break; }
        }
        if (!dup) allnames[allcount++] = names2[i];
    }
    qsort(allnames, allcount, sizeof(char*), cmp_str);

    for (int i = 0; i < allcount; i++) {
        const char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < count1; j++) {
            if (strcmp(names1[j], allnames[i]) == 0) { h1 = hashes1[j]; break; }
        }
        for (int j = 0; j < count2; j++) {
            if (strcmp(names2[j], allnames[i]) == 0) { h2 = hashes2[j]; break; }
        }
        if (!h1 && h2) {
            printf("Added: %s\n", allnames[i]);
        } else if (h1 && !h2) {
            printf("Removed: %s\n", allnames[i]);
        } else if (h1 && h2 && strcmp(h1, h2) != 0) {
            printf("Modified: %s\n", allnames[i]);
        }
    }

    free(allnames);
    for (int i = 0; i < count1; i++) { free(names1[i]); free(hashes1[i]); }
    free(names1); free(hashes1);
    for (int i = 0; i < count2; i++) { free(names2[i]); free(hashes2[i]); }
    free(names2); free(hashes2);
    return 0;
}

static int cmd_checkout(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    char **names, **hashes;
    int count;
    parse_commit_files(commit_hash, &names, &hashes, &count);

    for (int i = 0; i < count; i++) {
        char objpath[512];
        snprintf(objpath, sizeof(objpath), ".minigit/objects/%s", hashes[i]);
        size_t olen;
        char *odata = read_file(objpath, &olen);
        if (odata) {
            write_file(names[i], odata, olen);
            free(odata);
        }
    }

    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));
    write_file(".minigit/index", "", 0);

    printf("Checked out %s\n", commit_hash);

    for (int i = 0; i < count; i++) { free(names[i]); free(hashes[i]); }
    free(names); free(hashes);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    if (!file_exists(cpath)) {
        printf("Invalid commit\n");
        return 1;
    }

    write_file(".minigit/HEAD", commit_hash, strlen(commit_hash));
    write_file(".minigit/index", "", 0);

    printf("Reset to %s\n", commit_hash);
    return 0;
}

static int cmd_rm(const char *filename) {
    int count;
    char **lines = read_index(&count);
    int found = -1;
    for (int i = 0; i < count; i++) {
        if (strcmp(lines[i], filename) == 0) {
            found = i;
            break;
        }
    }
    if (found < 0) {
        printf("File not in index\n");
        for (int i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 1;
    }

    FILE *f = fopen(".minigit/index", "w");
    for (int i = 0; i < count; i++) {
        if (i != found) {
            fprintf(f, "%s\n", lines[i]);
        }
    }
    fclose(f);

    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char cpath[512];
    snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", commit_hash);
    size_t clen;
    char *cdata = read_file(cpath, &clen);
    if (!cdata) {
        printf("Invalid commit\n");
        return 1;
    }

    char ts[64] = "";
    char msg[1024] = "";
    char **fnames = NULL;
    char **fhashes = NULL;
    int fcount = 0;
    int fcap = 64;
    fnames = malloc(fcap * sizeof(char*));
    fhashes = malloc(fcap * sizeof(char*));

    int in_files = 0;
    char *saveptr = NULL;
    char *line = strtok_r(cdata, "\n", &saveptr);
    while (line) {
        if (strncmp(line, "timestamp: ", 11) == 0) {
            strncpy(ts, line + 11, sizeof(ts)-1);
        } else if (strncmp(line, "message: ", 9) == 0) {
            strncpy(msg, line + 9, sizeof(msg)-1);
        } else if (strcmp(line, "files:") == 0) {
            in_files = 1;
        } else if (in_files) {
            char *sp = strchr(line, ' ');
            if (sp) {
                if (fcount >= fcap) { fcap *= 2; fnames = realloc(fnames, fcap * sizeof(char*)); fhashes = realloc(fhashes, fcap * sizeof(char*)); }
                fnames[fcount] = strndup(line, sp - line);
                fhashes[fcount] = strdup(sp + 1);
                fcount++;
            }
        }
        line = strtok_r(NULL, "\n", &saveptr);
    }

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", ts);
    printf("Message: %s\n", msg);
    printf("Files:\n");
    /* Files should already be sorted from commit, but sort anyway */
    for (int i = 0; i < fcount; i++) {
        printf("  %s %s\n", fnames[i], fhashes[i]);
    }

    for (int i = 0; i < fcount; i++) { free(fnames[i]); free(fhashes[i]); }
    free(fnames); free(fhashes);
    free(cdata);
    return 0;
}

static int cmd_log(void) {
    size_t hlen;
    char *head = read_file(".minigit/HEAD", &hlen);
    if (!head || hlen == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }
    /* trim */
    char *h = head;
    while (*h && *h != '\n' && *h != '\r') h++;
    *h = '\0';
    if (strlen(head) == 0) {
        printf("No commits\n");
        free(head);
        return 0;
    }

    char current[64];
    strncpy(current, head, sizeof(current)-1);
    current[sizeof(current)-1] = '\0';
    free(head);

    int first = 1;
    while (strlen(current) > 0 && strcmp(current, "NONE") != 0) {
        char cpath[512];
        snprintf(cpath, sizeof(cpath), ".minigit/commits/%s", current);
        size_t clen;
        char *cdata = read_file(cpath, &clen);
        if (!cdata) break;

        /* Parse commit */
        char par[64] = "NONE";
        char ts[64] = "";
        char msg[1024] = "";

        char *line = strtok(cdata, "\n");
        while (line) {
            if (strncmp(line, "parent: ", 8) == 0) {
                strncpy(par, line + 8, sizeof(par)-1);
            } else if (strncmp(line, "timestamp: ", 11) == 0) {
                strncpy(ts, line + 11, sizeof(ts)-1);
            } else if (strncmp(line, "message: ", 9) == 0) {
                strncpy(msg, line + 9, sizeof(msg)-1);
            }
            line = strtok(NULL, "\n");
        }

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", ts);
        printf("Message: %s\n", msg);
        first = 0;

        strncpy(current, par, sizeof(current)-1);
        free(cdata);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: minigit <command> [args]\n");
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
