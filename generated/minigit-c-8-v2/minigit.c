#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

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

static int dir_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, sz, f);
    buf[rd] = '\0';
    if (out_len) *out_len = rd;
    fclose(f);
    return buf;
}

static void write_file(const char *path, const char *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror("fopen"); exit(1); }
    fwrite(data, 1, len, f);
    fclose(f);
}

static int cmd_init(void) {
    if (dir_exists(MINIGIT_DIR)) {
        printf("Repository already initialized\n");
        return 0;
    }
    mkdir(MINIGIT_DIR, 0755);
    mkdir(OBJECTS_DIR, 0755);
    mkdir(COMMITS_DIR, 0755);
    write_file(INDEX_FILE, "", 0);
    write_file(HEAD_FILE, "", 0);
    return 0;
}

static int cmd_add(const char *filename) {
    if (!file_exists(filename)) {
        printf("File not found\n");
        return 1;
    }

    size_t len;
    char *content = read_file(filename, &len);
    if (!content) {
        printf("File not found\n");
        return 1;
    }

    char hash[17];
    minihash((unsigned char *)content, len, hash);

    char obj_path[512];
    snprintf(obj_path, sizeof(obj_path), "%s/%s", OBJECTS_DIR, hash);
    if (!file_exists(obj_path)) {
        write_file(obj_path, content, len);
    }
    free(content);

    /* Check if already in index */
    size_t idx_len;
    char *index = read_file(INDEX_FILE, &idx_len);
    int found = 0;
    if (index && idx_len > 0) {
        char *line = strtok(index, "\n");
        while (line) {
            if (strcmp(line, filename) == 0) {
                found = 1;
                break;
            }
            line = strtok(NULL, "\n");
        }
    }
    free(index);

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
    size_t idx_len;
    char *index = read_file(INDEX_FILE, &idx_len);
    if (!index || idx_len == 0) {
        free(index);
        printf("Nothing to commit\n");
        return 1;
    }

    /* Parse index lines */
    char **files = NULL;
    int nfiles = 0;
    char *idx_copy = strdup(index);
    char *line = strtok(idx_copy, "\n");
    while (line) {
        if (strlen(line) > 0) {
            files = realloc(files, sizeof(char *) * (nfiles + 1));
            files[nfiles++] = strdup(line);
        }
        line = strtok(NULL, "\n");
    }
    free(idx_copy);
    free(index);

    if (nfiles == 0) {
        free(files);
        printf("Nothing to commit\n");
        return 1;
    }

    /* Sort filenames */
    qsort(files, nfiles, sizeof(char *), cmp_str);

    /* Get parent */
    size_t head_len;
    char *head = read_file(HEAD_FILE, &head_len);
    char parent[64] = "NONE";
    if (head && head_len > 0) {
        /* trim whitespace */
        char *p = head;
        while (*p && *p != '\n' && *p != '\r') p++;
        *p = '\0';
        if (strlen(head) > 0) {
            strncpy(parent, head, sizeof(parent) - 1);
            parent[sizeof(parent) - 1] = '\0';
        }
    }
    free(head);

    /* Build commit content */
    long ts = (long)time(NULL);

    /* First pass: compute size */
    size_t commit_size = 0;
    commit_size += snprintf(NULL, 0, "parent: %s\n", parent);
    commit_size += snprintf(NULL, 0, "timestamp: %ld\n", ts);
    commit_size += snprintf(NULL, 0, "message: %s\n", message);
    commit_size += snprintf(NULL, 0, "files:\n");

    for (int i = 0; i < nfiles; i++) {
        /* Read file and compute hash */
        size_t flen;
        char *fc = read_file(files[i], &flen);
        char fhash[17];
        if (fc) {
            minihash((unsigned char *)fc, flen, fhash);
            free(fc);
        } else {
            /* file might have been removed, use existing object */
            /* find the blob hash from objects dir - scan for matching filename content */
            strcpy(fhash, "0000000000000000");
        }
        commit_size += snprintf(NULL, 0, "%s %s\n", files[i], fhash);
    }

    char *commit_buf = malloc(commit_size + 1);
    int pos = 0;
    pos += sprintf(commit_buf + pos, "parent: %s\n", parent);
    pos += sprintf(commit_buf + pos, "timestamp: %ld\n", ts);
    pos += sprintf(commit_buf + pos, "message: %s\n", message);
    pos += sprintf(commit_buf + pos, "files:\n");

    for (int i = 0; i < nfiles; i++) {
        size_t flen;
        char *fc = read_file(files[i], &flen);
        char fhash[17];
        if (fc) {
            minihash((unsigned char *)fc, flen, fhash);
            free(fc);
        } else {
            strcpy(fhash, "0000000000000000");
        }
        pos += sprintf(commit_buf + pos, "%s %s\n", files[i], fhash);
        free(files[i]);
    }
    free(files);

    /* Hash commit content */
    char commit_hash[17];
    minihash((unsigned char *)commit_buf, pos, commit_hash);

    /* Write commit file */
    char commit_path[512];
    snprintf(commit_path, sizeof(commit_path), "%s/%s", COMMITS_DIR, commit_hash);
    write_file(commit_path, commit_buf, pos);
    free(commit_buf);

    /* Update HEAD */
    char head_content[18];
    snprintf(head_content, sizeof(head_content), "%s", commit_hash);
    write_file(HEAD_FILE, head_content, strlen(head_content));

    /* Clear index */
    write_file(INDEX_FILE, "", 0);

    printf("Committed %s\n", commit_hash);
    return 0;
}

static int cmd_status(void) {
    size_t idx_len;
    char *index = read_file(INDEX_FILE, &idx_len);
    printf("Staged files:\n");
    if (!index || idx_len == 0) {
        printf("(none)\n");
        free(index);
        return 0;
    }
    /* Check if there are any non-empty lines */
    int has_files = 0;
    char *copy = strdup(index);
    char *line = strtok(copy, "\n");
    while (line) {
        if (strlen(line) > 0) {
            printf("%s\n", line);
            has_files = 1;
        }
        line = strtok(NULL, "\n");
    }
    free(copy);
    free(index);
    if (!has_files) {
        printf("(none)\n");
    }
    return 0;
}

/* Parse commit file to extract file list. Returns array of "filename hash" strings. */
static int parse_commit_files(const char *commit_hash, char ***out_files, char ***out_hashes, int *out_count) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", COMMITS_DIR, commit_hash);
    size_t clen;
    char *data = read_file(path, &clen);
    if (!data) return -1;

    *out_count = 0;
    *out_files = NULL;
    *out_hashes = NULL;

    int in_files = 0;
    char *copy = strdup(data);
    char *line = strtok(copy, "\n");
    while (line) {
        if (strcmp(line, "files:") == 0) {
            in_files = 1;
        } else if (in_files && strlen(line) > 0) {
            char fname[512], fhash[32];
            if (sscanf(line, "%511s %31s", fname, fhash) == 2) {
                *out_files = realloc(*out_files, sizeof(char *) * (*out_count + 1));
                *out_hashes = realloc(*out_hashes, sizeof(char *) * (*out_count + 1));
                (*out_files)[*out_count] = strdup(fname);
                (*out_hashes)[*out_count] = strdup(fhash);
                (*out_count)++;
            }
        }
        line = strtok(NULL, "\n");
    }
    free(copy);
    free(data);
    return 0;
}

static int cmd_diff(const char *hash1, const char *hash2) {
    char **files1 = NULL, **hashes1 = NULL;
    char **files2 = NULL, **hashes2 = NULL;
    int n1 = 0, n2 = 0;

    if (parse_commit_files(hash1, &files1, &hashes1, &n1) != 0) {
        printf("Invalid commit\n");
        return 1;
    }
    if (parse_commit_files(hash2, &files2, &hashes2, &n2) != 0) {
        printf("Invalid commit\n");
        for (int i = 0; i < n1; i++) { free(files1[i]); free(hashes1[i]); }
        free(files1); free(hashes1);
        return 1;
    }

    /* Collect all unique filenames */
    char **all = NULL;
    int nall = 0;
    for (int i = 0; i < n1; i++) {
        int found = 0;
        for (int j = 0; j < nall; j++) if (strcmp(all[j], files1[i]) == 0) { found = 1; break; }
        if (!found) { all = realloc(all, sizeof(char *) * (nall + 1)); all[nall++] = files1[i]; }
    }
    for (int i = 0; i < n2; i++) {
        int found = 0;
        for (int j = 0; j < nall; j++) if (strcmp(all[j], files2[i]) == 0) { found = 1; break; }
        if (!found) { all = realloc(all, sizeof(char *) * (nall + 1)); all[nall++] = files2[i]; }
    }
    qsort(all, nall, sizeof(char *), cmp_str);

    for (int i = 0; i < nall; i++) {
        char *h1 = NULL, *h2 = NULL;
        for (int j = 0; j < n1; j++) if (strcmp(files1[j], all[i]) == 0) { h1 = hashes1[j]; break; }
        for (int j = 0; j < n2; j++) if (strcmp(files2[j], all[i]) == 0) { h2 = hashes2[j]; break; }

        if (h1 && !h2) {
            printf("Removed: %s\n", all[i]);
        } else if (!h1 && h2) {
            printf("Added: %s\n", all[i]);
        } else if (h1 && h2 && strcmp(h1, h2) != 0) {
            printf("Modified: %s\n", all[i]);
        }
    }

    free(all);
    for (int i = 0; i < n1; i++) { free(files1[i]); free(hashes1[i]); }
    for (int i = 0; i < n2; i++) { free(files2[i]); free(hashes2[i]); }
    free(files1); free(hashes1);
    free(files2); free(hashes2);
    return 0;
}

static int cmd_checkout(const char *commit_hash) {
    char commit_path[512];
    snprintf(commit_path, sizeof(commit_path), "%s/%s", COMMITS_DIR, commit_hash);
    if (!file_exists(commit_path)) {
        printf("Invalid commit\n");
        return 1;
    }

    char **files = NULL, **hashes = NULL;
    int nfiles = 0;
    parse_commit_files(commit_hash, &files, &hashes, &nfiles);

    for (int i = 0; i < nfiles; i++) {
        char obj_path[512];
        snprintf(obj_path, sizeof(obj_path), "%s/%s", OBJECTS_DIR, hashes[i]);
        size_t olen;
        char *content = read_file(obj_path, &olen);
        if (content) {
            write_file(files[i], content, olen);
            free(content);
        }
        free(files[i]);
        free(hashes[i]);
    }
    free(files);
    free(hashes);

    /* Update HEAD */
    write_file(HEAD_FILE, commit_hash, strlen(commit_hash));
    /* Clear index */
    write_file(INDEX_FILE, "", 0);

    printf("Checked out %s\n", commit_hash);
    return 0;
}

static int cmd_reset(const char *commit_hash) {
    char commit_path[512];
    snprintf(commit_path, sizeof(commit_path), "%s/%s", COMMITS_DIR, commit_hash);
    if (!file_exists(commit_path)) {
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
    size_t idx_len;
    char *index = read_file(INDEX_FILE, &idx_len);
    if (!index || idx_len == 0) {
        free(index);
        printf("File not in index\n");
        return 1;
    }

    /* Parse lines, rebuild without the target */
    char **lines = NULL;
    int nlines = 0;
    int found = 0;
    char *copy = strdup(index);
    char *line = strtok(copy, "\n");
    while (line) {
        if (strlen(line) > 0) {
            if (strcmp(line, filename) == 0) {
                found = 1;
            } else {
                lines = realloc(lines, sizeof(char *) * (nlines + 1));
                lines[nlines++] = strdup(line);
            }
        }
        line = strtok(NULL, "\n");
    }
    free(copy);
    free(index);

    if (!found) {
        for (int i = 0; i < nlines; i++) free(lines[i]);
        free(lines);
        printf("File not in index\n");
        return 1;
    }

    /* Rewrite index */
    FILE *f = fopen(INDEX_FILE, "w");
    for (int i = 0; i < nlines; i++) {
        fprintf(f, "%s\n", lines[i]);
        free(lines[i]);
    }
    fclose(f);
    free(lines);
    return 0;
}

static int cmd_show(const char *commit_hash) {
    char commit_path[512];
    snprintf(commit_path, sizeof(commit_path), "%s/%s", COMMITS_DIR, commit_hash);
    if (!file_exists(commit_path)) {
        printf("Invalid commit\n");
        return 1;
    }

    size_t clen;
    char *data = read_file(commit_path, &clen);
    if (!data) {
        printf("Invalid commit\n");
        return 1;
    }

    char timestamp[64] = "";
    char message[1024] = "";
    char **files = NULL, **hashes = NULL;
    int nfiles = 0;

    int in_files = 0;
    char *copy = strdup(data);
    char *line = strtok(copy, "\n");
    while (line) {
        if (strncmp(line, "timestamp: ", 11) == 0) {
            strncpy(timestamp, line + 11, sizeof(timestamp) - 1);
        } else if (strncmp(line, "message: ", 9) == 0) {
            strncpy(message, line + 9, sizeof(message) - 1);
        } else if (strcmp(line, "files:") == 0) {
            in_files = 1;
        } else if (in_files && strlen(line) > 0) {
            char fname[512], fhash[32];
            if (sscanf(line, "%511s %31s", fname, fhash) == 2) {
                files = realloc(files, sizeof(char *) * (nfiles + 1));
                hashes = realloc(hashes, sizeof(char *) * (nfiles + 1));
                files[nfiles] = strdup(fname);
                hashes[nfiles] = strdup(fhash);
                nfiles++;
            }
        }
        line = strtok(NULL, "\n");
    }
    free(copy);
    free(data);

    printf("commit %s\n", commit_hash);
    printf("Date: %s\n", timestamp);
    printf("Message: %s\n", message);
    printf("Files:\n");
    for (int i = 0; i < nfiles; i++) {
        printf("  %s %s\n", files[i], hashes[i]);
        free(files[i]);
        free(hashes[i]);
    }
    free(files);
    free(hashes);
    return 0;
}

static int cmd_log(void) {
    size_t head_len;
    char *head = read_file(HEAD_FILE, &head_len);
    if (!head || head_len == 0) {
        free(head);
        printf("No commits\n");
        return 0;
    }

    /* Trim */
    char *p = head;
    while (*p && *p != '\n' && *p != '\r') p++;
    *p = '\0';

    if (strlen(head) == 0) {
        free(head);
        printf("No commits\n");
        return 0;
    }

    char current[64];
    strncpy(current, head, sizeof(current) - 1);
    current[sizeof(current) - 1] = '\0';
    free(head);

    int first = 1;
    while (strcmp(current, "NONE") != 0 && strlen(current) > 0) {
        char commit_path[512];
        snprintf(commit_path, sizeof(commit_path), "%s/%s", COMMITS_DIR, current);

        size_t clen;
        char *commit_data = read_file(commit_path, &clen);
        if (!commit_data) break;

        /* Parse commit */
        char parent[64] = "NONE";
        char timestamp[64] = "";
        char message[1024] = "";

        char *copy = strdup(commit_data);
        char *line = strtok(copy, "\n");
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
        free(copy);
        free(commit_data);

        if (!first) printf("\n");
        printf("commit %s\n", current);
        printf("Date: %s\n", timestamp);
        printf("Message: %s\n", message);
        first = 0;

        strncpy(current, parent, sizeof(current) - 1);
        current[sizeof(current) - 1] = '\0';
    }

    return 0;
}

int main(int argc, char **argv) {
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
    } else if (strcmp(cmd, "status") == 0) {
        return cmd_status();
    } else if (strcmp(cmd, "log") == 0) {
        return cmd_log();
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
