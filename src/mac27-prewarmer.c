#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <pwd.h>
#include <fts.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <libkern/OSByteOrder.h>

// A full walk of /Applications opens ~155,000 files while kern.maxvnodes is 263,168 and already full, so every
// walk recycles most of the vnode table. The walk therefore runs at most once per MANIFEST_MAX_AGE_SEC and records
// what it warmed; the 4-hourly runs in between replay that manifest (~6,000 files) and only read pages that
// mincore() reports missing.
#define MANIFEST_MAX_AGE_SEC   (24 * 60 * 60)
#define MANIFEST_MAX_MISS_PCT  2

static uint64_t total_requested_bytes = 0;
static uint64_t total_already_resident = 0;
static uint64_t total_read_bytes      = 0;
static uint64_t total_resident_bytes  = 0;
static uint64_t total_arm_skipped     = 0;
static int files_warmed = 0;
static FILE *manifest_out = NULL;

// User configuration in ~/.config/mac27-prewarmer.conf: extra directories to scan and path fragments to skip.
// Written with the defaults below when missing; editing it makes the next run do a full walk.
#define MAX_CONF_ENTRIES 32
static char *conf_includes[MAX_CONF_ENTRIES];
static int conf_include_count = 0;
static char *conf_excludes[MAX_CONF_ENTRIES];
static int conf_exclude_count = 0;
static time_t conf_mtime = 0;

static const char *default_config =
    "# mac27-prewarmer configuration. After editing, run: ~/.local/bin/mac27-prewarmer --full\n"
    "# (otherwise the change is picked up by the next scheduled run).\n"
    "#\n"
    "# include <directory>  also scan this directory (dyld cache, /Applications and /System/Applications are always scanned)\n"
    "# exclude <text>       skip every file or folder whose path contains this text\n"
    "#\n"
    "# Only x86_64 Mach-O code, UI resources (.car .pak .metallib .nib .bin .dat) and fonts (.ttf .ttc .otf) are warmed.\n"
    "\n"
    "include /Library/Developer/CommandLineTools\n"
    "include /usr/local/Cellar\n"
    "include /System/Library/Fonts\n"
    "include ~/Library/Application Support/Claude/claude-code\n"
    "\n"
    "exclude /Affinity Photo 2.app/\n"
    "exclude /Digital Photo Professional 4.app/\n"
    "exclude /Keynote.app/\n"
    "exclude /Pages.app/\n"
    "exclude /Numbers.app/\n";

static const char *home_dir(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) {
        struct passwd *pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : NULL;
    }
    return (home && *home) ? home : NULL;
}

static void load_config(void) {
    const char *home = home_dir();
    if (!home) return;
    char dir[PATH_MAX], path[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/.config", home);
    if (snprintf(path, sizeof(path), "%s/mac27-prewarmer.conf", dir) >= (int)sizeof(path)) return;

    struct stat st;
    if (stat(path, &st) != 0) {
        mkdir(dir, 0755);
        FILE *out = fopen(path, "w");
        if (out) {
            fputs(default_config, out);
            fclose(out);
        }
        if (stat(path, &st) != 0) return;
    }
    conf_mtime = st.st_mtime;

    FILE *fp = fopen(path, "r");
    if (!fp) return;
    char *line = NULL;
    size_t cap = 0;
    while (getline(&line, &cap, fp) > 0) {
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' ' || line[n - 1] == '\t')) line[--n] = '\0';
        char *value = NULL;
        int is_include = 0;
        if (strncmp(line, "include ", 8) == 0) { value = line + 8; is_include = 1; }
        else if (strncmp(line, "exclude ", 8) == 0) { value = line + 8; }
        if (!value) continue;
        while (*value == ' ' || *value == '\t') value++;
        if (!*value) continue;

        char expanded[PATH_MAX];
        if (is_include && value[0] == '~' && value[1] == '/') {
            snprintf(expanded, sizeof(expanded), "%s/%s", home, value + 2);
        } else {
            snprintf(expanded, sizeof(expanded), "%s", value);
        }
        if (is_include && conf_include_count < MAX_CONF_ENTRIES) conf_includes[conf_include_count++] = strdup(expanded);
        if (!is_include && conf_exclude_count < MAX_CONF_ENTRIES) conf_excludes[conf_exclude_count++] = strdup(expanded);
    }
    free(line);
    fclose(fp);
}

// Directories are tested with a trailing slash so "/Keynote.app/" also matches the bundle directory itself
static int is_excluded(const char *path, int is_dir) {
    if (conf_exclude_count == 0) return 0;
    char with_slash[PATH_MAX];
    if (is_dir) snprintf(with_slash, sizeof(with_slash), "%s/", path);
    for (int i = 0; i < conf_exclude_count; i++) {
        if (strstr(is_dir ? with_slash : path, conf_excludes[i])) return 1;
    }
    return 0;
}

static size_t count_resident_pages(int fd, off_t offset, size_t length, char *vec) {
    const size_t page_sz = 4096;
    size_t num_pages = (length + page_sz - 1) / page_sz;
    memset(vec, 0, num_pages);
    size_t resident = 0;
    void *addr = mmap(NULL, length, PROT_READ, MAP_FILE | MAP_SHARED, fd, offset);
    if (addr == MAP_FAILED) return 0;
    // mincore() only inspects the page tables; the mapping is never dereferenced, so truncation cannot raise SIGBUS
    if (mincore(addr, length, vec) == 0) {
        for (size_t p = 0; p < num_pages; p++) {
            if (vec[p] & MINCORE_INCORE) resident++;
        }
    } else {
        memset(vec, 0, num_pages);
    }
    munmap(addr, length);
    return resident;
}

// Bring [start_offset, start_offset + length) into the Unified Buffer Cache. Pages that mincore() reports
// resident are skipped; only missing page runs are read with pread(), then residency is measured again.
static void warm_and_verify_range(int fd, off_t start_offset, off_t length) {
    if (length <= 0) return;
    const size_t page_sz = 4096;
    off_t aligned_off = (start_offset / page_sz) * page_sz;
    size_t remaining = (size_t)length + (size_t)(start_offset - aligned_off);

    const size_t window_sz = 32 * 1024 * 1024;
    const size_t io_buf_sz = 1024 * 1024;
    off_t cur_off = aligned_off;

    char *vec = (char *)malloc(window_sz / page_sz);
    uint8_t *io_buf = (uint8_t *)malloc(io_buf_sz);
    if (!vec || !io_buf) {
        free(vec);
        free(io_buf);
        return;
    }

    while (remaining > 0) {
        size_t chunk = (remaining > window_sz) ? window_sz : remaining;
        size_t num_pages = (chunk + page_sz - 1) / page_sz;

        size_t resident = count_resident_pages(fd, cur_off, chunk, vec);
        total_already_resident += resident * page_sz;

        size_t bytes_in_window = chunk;
        if (resident < num_pages) {
            size_t p = 0;
            while (p < num_pages) {
                while (p < num_pages && (vec[p] & MINCORE_INCORE)) p++;
                if (p >= num_pages) break;
                size_t p_start = p;
                while (p < num_pages && !(vec[p] & MINCORE_INCORE)) p++;
                size_t run_off = p_start * page_sz;
                size_t run_end = p * page_sz;
                if (run_end > chunk) run_end = chunk;
                size_t run_len = run_end - run_off;
                size_t done = 0;
                while (done < run_len) {
                    size_t to_read = run_len - done;
                    if (to_read > io_buf_sz) to_read = io_buf_sz;
                    ssize_t r = pread(fd, io_buf, to_read, cur_off + (off_t)run_off + (off_t)done);
                    if (r <= 0) { // EOF / concurrent truncation
                        bytes_in_window = run_off + done;
                        p = num_pages;
                        break;
                    }
                    done += (size_t)r;
                    total_read_bytes += (size_t)r;
                }
            }
            if (bytes_in_window == 0) break;
            resident = count_resident_pages(fd, cur_off, bytes_in_window, vec);
        }

        total_requested_bytes += ((bytes_in_window + page_sz - 1) / page_sz) * page_sz;
        total_resident_bytes  += resident * page_sz;

        if (bytes_in_window < chunk) break;
        cur_off += chunk;
        remaining -= chunk;
    }

    free(io_buf);
    free(vec);
}

static void warm_range_and_record(int fd, const char *path, off_t offset, off_t length) {
    warm_and_verify_range(fd, offset, length);
    files_warmed++;
    // Paths with tabs or newlines cannot be represented in the manifest; they are simply rediscovered by the next walk
    if (manifest_out && !strchr(path, '\t') && !strchr(path, '\n')) {
        fprintf(manifest_out, "%lld\t%lld\t%s\n", (long long)offset, (long long)length, path);
    }
}

static int is_hot_resource_ext(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return 0;
    static const char * const exts[] = {
        ".pak", ".car", ".metallib", ".nib", ".bin", ".dat", ".ttf", ".ttc", ".otf", NULL
    };
    for (int i = 0; exts[i]; i++) {
        if (strcmp(dot, exts[i]) == 0) return 1;
    }
    return 0;
}

static int size_in_range(off_t file_size) {
    return file_size >= 4096 && file_size <= (off_t)2 * 1024 * 1024 * 1024;
}

static void prewarm_file_entry(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return;

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || !size_in_range(st.st_size)) {
        close(fd);
        return;
    }
    off_t file_size = st.st_size;

    uint8_t buf[512];
    ssize_t n = pread(fd, buf, sizeof(buf), 0);
    if (n < 32) {
        close(fd);
        return;
    }

    // 1. macOS dyld_shared_cache_x86_64h*
    if (memcmp(buf, "dyld_v1 x86_64", 14) == 0 || strstr(path, "dyld_shared_cache_x86_64h.") != NULL) {
        warm_range_and_record(fd, path, 0, file_size);
        close(fd);
        return;
    }

    // 2. Universal 2 Fat Binary (0xCAFEBABE): fault ONLY x86_64 slice, skip arm64!
    uint32_t magic = *(uint32_t *)buf;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        struct fat_header *fh = (struct fat_header *)buf;
        uint32_t narch = OSSwapBigToHostInt32(fh->nfat_arch);
        if (narch >= 1 && narch <= 8 && n >= (ssize_t)(sizeof(struct fat_header) + narch * sizeof(struct fat_arch))) {
            struct fat_arch *archs = (struct fat_arch *)(buf + sizeof(struct fat_header));
            for (uint32_t i = 0; i < narch; i++) {
                cpu_type_t cputype = (cpu_type_t)OSSwapBigToHostInt32(archs[i].cputype);
                uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
                uint32_t size   = OSSwapBigToHostInt32(archs[i].size);
                if (cputype == CPU_TYPE_X86_64 && (off_t)offset + (off_t)size <= file_size) {
                    warm_range_and_record(fd, path, (off_t)offset, (off_t)size);
                } else if (cputype == CPU_TYPE_ARM64) {
                    total_arm_skipped += size;
                }
            }
        }
    } else if (magic == MH_MAGIC_64) {
        struct mach_header_64 *mh = (struct mach_header_64 *)buf;
        if (mh->cputype == CPU_TYPE_X86_64) {
            warm_range_and_record(fd, path, 0, file_size);
        }
    } else if (is_hot_resource_ext(path)) {
        warm_range_and_record(fd, path, 0, file_size);
    }
    close(fd);
}

static int manifest_path(char *out, size_t out_sz, int create_dir) {
    const char *home = home_dir();
    if (!home) return -1;
    char dir[PATH_MAX];
    if (snprintf(dir, sizeof(dir), "%s/Library/Caches/com.ericzhu.mac27prewarmer", home) >= (int)sizeof(dir)) return -1;
    if (create_dir) mkdir(dir, 0700);
    if (snprintf(out, out_sz, "%s/manifest.tsv", dir) >= (int)out_sz) return -1;
    return 0;
}

// Replays the manifest. Returns 0 on success, -1 if it is missing, stale, or too many of its files have changed
// (apps updated or removed), in which case the caller falls back to a full walk.
static int run_from_manifest(const char *mpath) {
    struct stat mst;
    if (stat(mpath, &mst) != 0 || mst.st_size == 0) return -1;
    if (time(NULL) - mst.st_mtime > MANIFEST_MAX_AGE_SEC) return -1;
    if (conf_mtime > mst.st_mtime) return -1; // configuration edited since the last walk

    FILE *fp = fopen(mpath, "r");
    if (!fp) return -1;

    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    int entries = 0, missed = 0;
    while ((len = getline(&line, &cap, fp)) > 0) {
        if (line[len - 1] == '\n') line[len - 1] = '\0';
        char *end1 = NULL, *end2 = NULL;
        long long offset = strtoll(line, &end1, 10);
        if (!end1 || *end1 != '\t') continue;
        long long length = strtoll(end1 + 1, &end2, 10);
        if (!end2 || *end2 != '\t' || offset < 0 || length <= 0) continue;
        const char *path = end2 + 1;
        entries++;

        int fd = open(path, O_RDONLY | O_NOFOLLOW);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || (off_t)(offset + length) > st.st_size) {
            if (fd >= 0) close(fd);
            missed++;
            continue;
        }
        warm_and_verify_range(fd, (off_t)offset, (off_t)length);
        files_warmed++;
        close(fd);
    }
    free(line);
    fclose(fp);

    if (entries == 0 || missed * 100 > entries * MANIFEST_MAX_MISS_PCT) return -1;
    return 0;
}

static int run_full_walk(const char *mpath) {
    const char *candidates[] = {
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld",
        "/Applications",
        "/System/Applications",
        NULL
    };

    char *valid_paths[8 + MAX_CONF_ENTRIES] = {0};
    int vcount = 0;
    struct stat st;
    for (int i = 0; candidates[i]; i++) {
        if (candidates[i][0] && stat(candidates[i], &st) == 0) {
            valid_paths[vcount++] = (char *)candidates[i];
        }
    }
    for (int i = 0; i < conf_include_count; i++) {
        if (stat(conf_includes[i], &st) == 0 && S_ISDIR(st.st_mode)) {
            valid_paths[vcount++] = conf_includes[i];
        }
    }
    valid_paths[vcount] = NULL;
    if (vcount == 0) return 0;

    char tmp_path[PATH_MAX] = {0};
    if (mpath && snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", mpath) < (int)sizeof(tmp_path)) {
        manifest_out = fopen(tmp_path, "w");
    }

    FTS *ftsp = fts_open(valid_paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!ftsp) {
        if (manifest_out) { fclose(manifest_out); manifest_out = NULL; unlink(tmp_path); }
        return 1;
    }

    FTSENT *ent;
    while ((ent = fts_read(ftsp)) != NULL) {
        if (ent->fts_info == FTS_D && is_excluded(ent->fts_path, 1)) {
            fts_set(ftsp, ent, FTS_SKIP);
            continue;
        }
        // fts already has the size; skip files that can never qualify without opening them
        if (ent->fts_info == FTS_F && ent->fts_statp && size_in_range(ent->fts_statp->st_size)
            && !is_excluded(ent->fts_path, 0)) {
            prewarm_file_entry(ent->fts_path);
        }
    }
    fts_close(ftsp);

    if (manifest_out) {
        int ok = (fflush(manifest_out) == 0);
        fclose(manifest_out);
        manifest_out = NULL;
        if (!ok || rename(tmp_path, mpath) != 0) unlink(tmp_path);
    }
    return 0;
}

int main(int argc, char *argv[]) {
    int force_full = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--delay") == 0 && i + 1 < argc) {
            int delay_sec = atoi(argv[++i]);
            if (delay_sec > 0 && delay_sec <= 600) {
                sleep((unsigned int)delay_sec);
            }
        } else if (strcmp(argv[i], "--full") == 0) {
            force_full = 1;
        }
    }

    uint64_t phys_ram = 0;
    size_t len = sizeof(phys_ram);
    sysctlbyname("hw.memsize", &phys_ram, &len, NULL, 0);

    load_config();

    char mpath[PATH_MAX] = {0};
    int have_manifest_path = (manifest_path(mpath, sizeof(mpath), 1) == 0);

    const char *mode = "manifest replay";
    if (force_full || !have_manifest_path || run_from_manifest(mpath) != 0) {
        // Counters from a rejected manifest replay still describe real work, but the walk revisits the same files
        total_requested_bytes = total_already_resident = total_read_bytes = total_resident_bytes = 0;
        files_warmed = 0;
        mode = "full walk";
        int rc = run_full_walk(have_manifest_path ? mpath : NULL);
        if (rc != 0) return rc;
    }

    double req_mb  = (double)total_requested_bytes  / 1048576.0;
    double res_mb  = (double)total_resident_bytes   / 1048576.0;
    double had_mb  = (double)total_already_resident / 1048576.0;
    double read_mb = (double)total_read_bytes       / 1048576.0;
    double pct     = (req_mb > 0.0) ? (res_mb / req_mb * 100.0) : 0.0;

    time_t now = time(NULL);
    char tbuf[32];
    strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S", localtime(&now));
    printf("[Mac27-64GB-DRAM-Engine] %s | %s | %d files | config: %d include, %d exclude (Total DRAM: %.0f GB):\n",
           tbuf, mode, files_warmed, conf_include_count, conf_exclude_count, (double)phys_ram / (1024.0 * 1024.0 * 1024.0));
    printf("  -> Requested x86_64 + dyld + Assets : %.1f MB (%.2f GB)\n", req_mb, req_mb / 1024.0);
    printf("  -> Already in RAM before this run   : %.1f MB\n", had_mb);
    printf("  -> Read from disk by this run       : %.1f MB\n", read_mb);
    printf("  -> mincore() Verified In-RAM Pages  : %.1f MB (%.2f GB | %.1f%% residency)\n",
           res_mb, res_mb / 1024.0, pct);
    if (total_arm_skipped > 0) {
        printf("  -> Dead arm64 Bloat Skipped         : %.1f MB (%.2f GB)\n",
               (double)total_arm_skipped / 1048576.0,
               (double)total_arm_skipped / (1024.0 * 1048576.0));
    }
    return 0;
}
