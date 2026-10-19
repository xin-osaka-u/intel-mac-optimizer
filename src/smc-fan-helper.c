#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <errno.h>
#include <time.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <IOKit/IOKitLib.h>

#define HEARTBEAT_PATH "/tmp/autogpu.heartbeat"
#define WATCHDOG_LOCK  "/var/run/smc-fan-watchdog.lock"
#define WATCHDOG_TIMEOUT_SEC 10

typedef struct { char major; char minor; char build; char reserved[1]; UInt16 release; } SMCKeyData_vers_t;
typedef struct { UInt16 version; UInt16 length; UInt32 cpuPLimit; UInt32 gpuPLimit; UInt32 memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef unsigned char SMCBytes_t[32];
typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

static UInt32 strtoul_key(const char *str) {
    return ((unsigned char)str[0] << 24) | ((unsigned char)str[1] << 16) | ((unsigned char)str[2] << 8) | (unsigned char)str[3];
}

static float smc_read_float(io_connect_t conn, const char *key_str, float fallback) {
    SMCKeyData_t in = {0}, out = {0};
    size_t outSize = sizeof(SMCKeyData_t);
    in.key = strtoul_key(key_str);
    in.data8 = 9;
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof(in), &out, &outSize) != kIOReturnSuccess || out.result != 0)
        return fallback;
    UInt32 dSize = out.keyInfo.dataSize;
    UInt32 dType = out.keyInfo.dataType;
    memset(&in, 0, sizeof(in));
    in.key = strtoul_key(key_str);
    in.keyInfo.dataSize = dSize;
    in.data8 = 5;
    memset(&out, 0, sizeof(out));
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof(in), &out, &outSize) != kIOReturnSuccess || out.result != 0)
        return fallback;
    if (dType == strtoul_key("flt ") && dSize == 4) {
        float f = fallback;
        memcpy(&f, out.bytes, 4);
        return (isfinite(f) && f > 500.0f && f < 8000.0f) ? f : fallback;
    } else if (dType == strtoul_key("fpe2") && dSize == 2) {
        UInt16 raw = (out.bytes[0] << 8) | out.bytes[1];
        float f = raw / 4.0f;
        return (isfinite(f) && f > 500.0f && f < 8000.0f) ? f : fallback;
    }
    return fallback;
}

static int smc_write_bytes(io_connect_t conn, const char *key_str, const void *data, UInt32 size) {
    SMCKeyData_t in = {0}, out = {0};
    size_t outSize = sizeof(SMCKeyData_t);
    in.key = strtoul_key(key_str);
    in.data8 = 9;
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof(in), &out, &outSize) != kIOReturnSuccess || out.result != 0)
        return -1;
    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = 6;
    memcpy(in.bytes, data, size);
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof(in), &out, &outSize) != kIOReturnSuccess || out.result != 0)
        return -2;
    return 0;
}

static int parse_strict_float(const char *s, float *out_val) {
    if (!s || !*s) return -1;
    char *endptr = NULL;
    errno = 0;
    float val = strtof(s, &endptr);
    if (errno != 0 || endptr == s || *endptr != '\0' || !isfinite(val)) {
        return -1;
    }
    *out_val = val;
    return 0;
}

// Root helper NEVER creates or writes files in /tmp; lock lives in root-only /var/run, and /tmp/autogpu.heartbeat is read-only via lstat()
static void ensure_watchdog_running(void) {
    int lock_fd = open(WATCHDOG_LOCK, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (lock_fd < 0) return;
    if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
        close(lock_fd);
        return;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(lock_fd);
        return;
    }
    if (pid > 0) {
        close(lock_fd);
        return;
    }
    setsid();
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);

    while (1) {
        sleep(3);
        struct stat st;
        // Use lstat and require regular file (reject symlinks)
        if (lstat(HEARTBEAT_PATH, &st) != 0 || !S_ISREG(st.st_mode)) {
            io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
            if (svc) {
                io_connect_t c = 0;
                if (IOServiceOpen(svc, mach_task_self(), 0, &c) == kIOReturnSuccess) {
                    unsigned char mode = 0;
                    smc_write_bytes(c, "F0Md", &mode, 1);
                    smc_write_bytes(c, "F1Md", &mode, 1);
                    IOServiceClose(c);
                }
                IOObjectRelease(svc);
            }
            break;
        }
        time_t now = time(NULL);
        if (now - st.st_mtime >= WATCHDOG_TIMEOUT_SEC) {
            io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
            if (svc) {
                io_connect_t c = 0;
                if (IOServiceOpen(svc, mach_task_self(), 0, &c) == kIOReturnSuccess) {
                    unsigned char mode = 0;
                    smc_write_bytes(c, "F0Md", &mode, 1);
                    smc_write_bytes(c, "F1Md", &mode, 1);
                    IOServiceClose(c);
                }
                IOObjectRelease(svc);
            }
            break;
        }
    }
    flock(lock_fd, LOCK_UN);
    close(lock_fd);
    _exit(0);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <auto | full | left_rpm right_rpm>\n", argv[0]);
        return 1;
    }
    if (setuid(0) != 0) {
        fprintf(stderr, "Error: setuid(0) failed\n");
        return 4;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 2;
    io_connect_t conn = 0;
    if (IOServiceOpen(service, mach_task_self(), 0, &conn) != kIOReturnSuccess) {
        IOObjectRelease(service);
        return 3;
    }

    float f0Min = smc_read_float(conn, "F0Mn", 1836.0f);
    float f0Max = smc_read_float(conn, "F0Mx", 5616.0f);
    float f1Min = smc_read_float(conn, "F1Mn", 1700.0f);
    float f1Max = smc_read_float(conn, "F1Mx", 5200.0f);

    int rc = 0;
    if (strcmp(argv[1], "auto") == 0) {
        unsigned char mode = 0;
        if (smc_write_bytes(conn, "F0Md", &mode, 1) != 0) rc = 5;
        if (smc_write_bytes(conn, "F1Md", &mode, 1) != 0) rc = 5;
    } else if (strcmp(argv[1], "full") == 0) {
        ensure_watchdog_running();
        unsigned char mode = 1;
        if (smc_write_bytes(conn, "F0Md", &mode, 1) != 0) rc = 5;
        if (smc_write_bytes(conn, "F1Md", &mode, 1) != 0) rc = 5;
        if (smc_write_bytes(conn, "F0Tg", &f0Max, 4) != 0) rc = 6;
        if (smc_write_bytes(conn, "F1Tg", &f1Max, 4) != 0) rc = 6;
    } else if (argc >= 3) {
        float f0 = 0.0f, f1 = 0.0f;
        if (parse_strict_float(argv[1], &f0) != 0 || parse_strict_float(argv[2], &f1) != 0) {
            IOServiceClose(conn);
            IOObjectRelease(service);
            fprintf(stderr, "Error: invalid or non-finite RPM arguments\n");
            return 7;
        }
        if (f0 < f0Min) f0 = f0Min;
        if (f0 > f0Max) f0 = f0Max;
        if (f1 < f1Min) f1 = f1Min;
        if (f1 > f1Max) f1 = f1Max;

        ensure_watchdog_running();

        unsigned char mode = 1;
        if (smc_write_bytes(conn, "F0Md", &mode, 1) != 0) rc = 5;
        if (smc_write_bytes(conn, "F1Md", &mode, 1) != 0) rc = 5;
        if (smc_write_bytes(conn, "F0Tg", &f0, 4) != 0) rc = 6;
        if (smc_write_bytes(conn, "F1Tg", &f1, 4) != 0) rc = 6;
    } else {
        rc = 1;
    }

    IOServiceClose(conn);
    IOObjectRelease(service);
    return rc;
}
