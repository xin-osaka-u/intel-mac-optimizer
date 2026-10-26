#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Carbon/Carbon.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <spawn.h>
#include <fcntl.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <math.h>

#define HEARTBEAT_PATH "/tmp/autogpu.heartbeat"
#define LOG_PATH       "/tmp/autogpu.log"

extern char **environ;

typedef NS_ENUM(NSInteger, AutoGPUMode) {
    AutoGPUModeSmart = 0,
    AutoGPUModeForceIntegrated = 1,
    AutoGPUModeForceDiscrete = 2
};

typedef NS_ENUM(NSInteger, FanControlMode) {
    FanModeSmart5D = 0,
    FanModeAppleAuto = 1,
    FanModeFullBlast = 2
};

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

typedef struct {
    UInt32 key;
    UInt32 dataSize;
    UInt32 dataType;
    BOOL valid;
} SMCCachedKey;

typedef struct {
    int igpuUtil;
    int dgpuActivity;
    int dgpuDieTemp;
    int dgpuPowerW;
} GPUTelemetry;

typedef struct {
    double startTempIGPU;
    double startTempDGPU;
    double startTempMeeting;
    double midTempIGPU;
    double midTempDGPU;
    double midTempMeeting;
    double fullTemp;
    double emergencyTemp;
    double midRatioNormal;
    double midRatioMeeting;
    double purgeTempLeft;
    double purgeTempRight;
    double purgeTempMeeting;
    double maxStepUpRPM;
    double maxStepDownRPM;
    double deadbandRPM;
} ThermalConfig;

static void log_autogpu(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    struct stat st;
    int flags = O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW;
    if (lstat(LOG_PATH, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 512 * 1024) {
        flags = O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW;
    }
    int fd = open(LOG_PATH, flags, 0644);
    if (fd >= 0) {
        time_t now = time(NULL);
        struct tm tm_now;
        localtime_r(&now, &tm_now);
        char tbuf[32];
        strftime(tbuf, sizeof(tbuf), "%Y-%m-%d %H:%M:%S", &tm_now);
        NSString *line = [NSString stringWithFormat:@"[%s] %@\n", tbuf, msg];
        const char *utf8 = [line UTF8String];
        if (utf8) write(fd, utf8, strlen(utf8));
        close(fd);
    }
}

static void touch_heartbeat_file(void) {
    int fd = open(HEARTBEAT_PATH, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, 0644);
    if (fd >= 0) {
        time_t now = time(NULL);
        write(fd, &now, sizeof(now));
        close(fd);
    }
}

static void remove_heartbeat_file(void) {
    unlink(HEARTBEAT_PATH);
}

static double clamp_val(double v, double lo, double hi, double fallback) {
    if (!isfinite(v)) return fallback;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static UInt32 strtoul_key(const char *str) {
    return ((unsigned char)str[0] << 24) | ((unsigned char)str[1] << 16) | ((unsigned char)str[2] << 8) | (unsigned char)str[3];
}

#define MAX_SMC_CACHE_KEYS 64
static SMCCachedKey g_keyCache[MAX_SMC_CACHE_KEYS];
static int g_keyCacheCount = 0;

static double read_smc_fast(io_connect_t conn, const char *key_str) {
    if (!conn) return -999.0;
    UInt32 k = strtoul_key(key_str);
    SMCCachedKey *cached = NULL;
    for (int i = 0; i < g_keyCacheCount; i++) {
        if (g_keyCache[i].key == k) { cached = &g_keyCache[i]; break; }
    }
    SMCKeyData_t in, out;
    size_t outSize = sizeof(SMCKeyData_t);
    if (!cached && g_keyCacheCount < MAX_SMC_CACHE_KEYS) {
        memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
        in.key = k;
        in.data8 = 9;
        if (IOConnectCallStructMethod(conn, 2, &in, sizeof(in), &out, &outSize) == kIOReturnSuccess && out.result == 0) {
            cached = &g_keyCache[g_keyCacheCount++];
            cached->key = k;
            cached->dataSize = out.keyInfo.dataSize;
            cached->dataType = out.keyInfo.dataType;
            cached->valid = YES;
        } else {
            return -999.0;
        }
    }
    if (!cached || !cached->valid) return -999.0;

    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = k;
    in.keyInfo.dataSize = cached->dataSize;
    in.data8 = 5;
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof(in), &out, &outSize) != kIOReturnSuccess || out.result != 0)
        return -999.0;

    if (cached->dataType == 0x73703738 && cached->dataSize == 2) { // 'sp78'
        int16_t raw = (out.bytes[0] << 8) | out.bytes[1];
        return raw / 256.0;
    } else if (cached->dataType == 0x666c7420 && cached->dataSize == 4) { // 'flt '
        float f; memcpy(&f, out.bytes, 4); return isfinite(f) ? (double)f : -999.0;
    } else if (cached->dataType == 0x66706532 && cached->dataSize == 2) { // 'fpe2'
        UInt16 raw = (out.bytes[0] << 8) | out.bytes[1];
        return raw / 4.0;
    } else if (cached->dataType == 0x75693820 && cached->dataSize == 1) { // 'ui8 ' (e.g. F0Md / F1Md)
        return (double)out.bytes[0];
    }
    return -998.0;
}

static int set_gpu_state(io_connect_t conn, uint64_t state, uint64_t arg) {
    uint64_t scalarI[3] = { 1, state, arg };
    return IOConnectCallScalarMethod(conn, 2, scalarI, 3, NULL, NULL);
}

// Raw value last returned by the mux, kept only so unusual values can be logged
static uint64_t g_rawMuxState = 1;

// Returns 0 for the discrete GPU and 1 for the integrated GPU. The mux reports 0 for discrete and "non-zero" for
// integrated; it is not always exactly 1 (it was neither 0 nor 1 while the display slept), and comparing against 1
// made every tick issue a force-switch during display sleep (1,272 times in one day).
static uint64_t get_current_gpu(io_connect_t conn) {
    uint64_t scalarI[2] = { 1, 7 };
    uint64_t out = 0;
    uint32_t outCount = 1;
    if (IOConnectCallScalarMethod(conn, 3, scalarI, 2, &out, &outCount) == kIOReturnSuccess) {
        g_rawMuxState = out;
        return (out != 0) ? 1 : 0;
    }
    return 1;
}

// Detect only physical external monitors registered under IODisplay (ignores Sidecar, AirPlay, and virtual displays)
static BOOL has_physical_external_display(void) {
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplay"), &iter) != kIOReturnSuccess)
        return NO;
    BOOL foundExt = NO;
    io_service_t entry;
    while ((entry = IOIteratorNext(iter)) != 0) {
        CFTypeRef clsRef = IORegistryEntryCreateCFProperty(entry, CFSTR("IOClass"), kCFAllocatorDefault, 0);
        if (clsRef) {
            if (CFGetTypeID(clsRef) == CFStringGetTypeID()) {
                NSString *cls = (__bridge NSString *)clsRef;
                if (![cls isEqualToString:@"AppleBacklightDisplay"]) {
                    foundExt = YES;
                }
            }
            CFRelease(clsRef);
        }
        IOObjectRelease(entry);
        if (foundExt) break;
    }
    IOObjectRelease(iter);
    return foundExt;
}

// macOS CPU speed limit in percent (100 = not throttled). This is what kernel_task enforces when any
// thermal zone trips, including ones this fan curve does not read (Thunderbolt, VRM, PCH, battery).
static int read_cpu_speed_limit(void) {
    CFDictionaryRef status = NULL;
    if (IOPMCopyCPUPowerStatus(&status) != kIOReturnSuccess || !status) return 100;
    int limit = 100;
    CFNumberRef num = CFDictionaryGetValue(status, CFSTR("CPU_Speed_Limit")); // kIOPMCPUPowerLimitProcessorSpeedKey
    if (num && CFGetTypeID(num) == CFNumberGetTypeID()) {
        CFNumberGetValue(num, kCFNumberIntType, &limit);
    }
    CFRelease(status);
    return (limit > 0 && limit <= 100) ? limit : 100;
}

// Thread-safe AppleEvent query for Google Chrome active tab URL without NSAppleScript
static NSString *query_chrome_url_ae(BOOL *outTimedOut, NSInteger *outErrCode) {
    if (outTimedOut) *outTimedOut = NO;
    if (outErrCode) *outErrCode = 0;
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.google.Chrome"].count == 0) {
        return nil;
    }
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithBundleIdentifier:@"com.google.Chrome"];
    NSAppleEventDescriptor *winSpec = [NSAppleEventDescriptor recordDescriptor];
    [winSpec setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'cwin'] forKeyword:'want'];
    [winSpec setDescriptor:[NSAppleEventDescriptor nullDescriptor] forKeyword:'from'];
    [winSpec setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:'indx'] forKeyword:'form'];
    [winSpec setDescriptor:[NSAppleEventDescriptor descriptorWithInt32:1] forKeyword:'seld'];
    AEDesc winObjDesc;
    if (AECoerceDesc([winSpec aeDesc], typeObjectSpecifier, &winObjDesc) != noErr) return nil;
    NSAppleEventDescriptor *winObj = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&winObjDesc];

    NSAppleEventDescriptor *tabSpec = [NSAppleEventDescriptor recordDescriptor];
    [tabSpec setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'prop'] forKeyword:'want'];
    [tabSpec setDescriptor:winObj forKeyword:'from'];
    [tabSpec setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:'prop'] forKeyword:'form'];
    [tabSpec setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'acTa'] forKeyword:'seld'];
    AEDesc tabObjDesc;
    if (AECoerceDesc([tabSpec aeDesc], typeObjectSpecifier, &tabObjDesc) != noErr) return nil;
    NSAppleEventDescriptor *tabObj = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&tabObjDesc];

    NSAppleEventDescriptor *urlSpec = [NSAppleEventDescriptor recordDescriptor];
    [urlSpec setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'prop'] forKeyword:'want'];
    [urlSpec setDescriptor:tabObj forKeyword:'from'];
    [urlSpec setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:'prop'] forKeyword:'form'];
    [urlSpec setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:'URL '] forKeyword:'seld'];
    AEDesc urlObjDesc;
    if (AECoerceDesc([urlSpec aeDesc], typeObjectSpecifier, &urlObjDesc) != noErr) return nil;
    NSAppleEventDescriptor *urlObj = [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&urlObjDesc];

    NSAppleEventDescriptor *ev = [NSAppleEventDescriptor appleEventWithEventClass:kAECoreSuite
                                                                          eventID:kAEGetData
                                                                 targetDescriptor:target
                                                                         returnID:kAutoGenerateReturnID
                                                                    transactionID:kAnyTransactionID];
    [ev setParamDescriptor:urlObj forKeyword:keyDirectObject];

    NSError *err = nil;
    NSAppleEventDescriptor *reply = [ev sendEventWithOptions:NSAppleEventSendWaitForReply | NSAppleEventSendNeverInteract
                                                     timeout:1.0
                                                       error:&err];
    if (err) {
        if (err.code == errAETimeout && outTimedOut) *outTimedOut = YES;
        if (outErrCode) *outErrCode = err.code;
        return nil;
    }
    NSAppleEventDescriptor *errn = [reply paramDescriptorForKeyword:'errn'];
    if (errn && [errn int32Value] != 0) {
        if (outErrCode) *outErrCode = [errn int32Value];
        return nil;
    }
    return [[reply paramDescriptorForKeyword:keyDirectObject] stringValue];
}

static GPUTelemetry read_gpu_telemetry(BOOL needAMDDetails) {
    GPUTelemetry t = {0, 0, 0, 0};
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) != kIOReturnSuccess)
        return t;
    io_service_t entry;
    while ((entry = IOIteratorNext(iter)) != 0) {
        CFTypeRef classRef = IORegistryEntryCreateCFProperty(entry, CFSTR("IOClass"), kCFAllocatorDefault, 0);
        if (classRef) {
            NSString *cls = (__bridge NSString *)classRef;
            BOOL isIntel = [cls containsString:@"Intel"];
            BOOL isAMD   = needAMDDetails && [cls containsString:@"AMD"];
            if (isIntel || isAMD) {
                CFTypeRef statsRef = IORegistryEntryCreateCFProperty(entry, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
                if (statsRef && CFGetTypeID(statsRef) == CFDictionaryGetTypeID()) {
                    NSDictionary *stats = (__bridge NSDictionary *)statsRef;
                    if (isIntel) {
                        NSNumber *u = stats[@"Device Utilization %"];
                        if (u) t.igpuUtil = [u intValue];
                    } else if (isAMD && stats[@"Temperature(C)"]) {
                        t.dgpuDieTemp  = [stats[@"Temperature(C)"] intValue];
                        t.dgpuActivity = [stats[@"GPU Activity(%)"] intValue];
                        t.dgpuPowerW   = [stats[@"Total Power(W)"] intValue];
                    }
                }
                if (statsRef) CFRelease(statsRef);
            }
            CFRelease(classRef);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    return t;
}

// Inspects the AMD IOAccelerator user clients. When snapshotOnly is NO, formats a summary of non-daemon
// processes holding AMD acceleration handles (highlighting any new handles opened since prevCreators and any
// command queues that submitted work within the last 15s), then updates *prevCreatorsRef.
static NSString *query_amd_accel_holders(NSSet<NSString *> * __strong *prevCreatorsRef, BOOL snapshotOnly) {
    static NSSet<NSString *> *ignoredDaemons = nil;
    if (!ignoredDaemons) {
        ignoredDaemons = [NSSet setWithArray:@[
            @"WindowServer", @"loginwindow", @"TouchBarServer", @"ControlCenter", @"ControlStrip",
            @"NotificationCent", @"Dock", @"DockHelper", @"com.apple.dock.e", @"Finder", @"Spotlight",
            @"WallpaperAerials", @"CursorUIViewServ", @"AccessibilityUIS", @"TextInputMenuAge",
            @"TextInputSwitche", @"SCIM_Extension", @"TCIM_Extension", @"JapaneseIM-Romaj",
            @"iconservicesagen", @"CoreServicesUIAg", @"UserNotification", @"PowerChime",
            @"coreautha", @"SafeEjectGPUServ", @"systemmigrationd", @"MTLAssetUpgrader",
            @"LinkedNotesUISer", @"AutoGPU", @"Turbo Boost Swit"
        ]];
    }

    io_iterator_t iter;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) != kIOReturnSuccess)
        return @"none";

    NSMutableSet<NSString *> *curCreators = [NSMutableSet set];
    NSMutableArray<NSString *> *holders = snapshotOnly ? nil : [NSMutableArray array];
    NSMutableArray<NSString *> *newHolders = snapshotOnly ? nil : [NSMutableArray array];
    NSMutableArray<NSString *> *activeQueues = snapshotOnly ? nil : [NSMutableArray array];
    NSSet<NSString *> *prevCreators = prevCreatorsRef ? *prevCreatorsRef : nil;
    uint64_t nowMat = mach_absolute_time();

    io_service_t entry;
    while ((entry = IOIteratorNext(iter)) != 0) {
        CFTypeRef classRef = IORegistryEntryCreateCFProperty(entry, CFSTR("IOClass"), kCFAllocatorDefault, 0);
        if (classRef) {
            NSString *cls = (__bridge NSString *)classRef;
            if ([cls containsString:@"AMD"]) {
                io_iterator_t childIter = 0;
                if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) == kIOReturnSuccess) {
                    io_registry_entry_t child;
                    while ((child = IOIteratorNext(childIter)) != 0) {
                        CFTypeRef creatorRef = IORegistryEntryCreateCFProperty(child, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
                        if (creatorRef && CFGetTypeID(creatorRef) == CFStringGetTypeID()) {
                            NSString *creator = (__bridge NSString *)creatorRef;
                            [curCreators addObject:creator];
                            if (!snapshotOnly) {
                                NSRange sep = [creator rangeOfString:@", "];
                                NSString *proc = (sep.location != NSNotFound) ? [creator substringFromIndex:NSMaxRange(sep)] : creator;
                                if (proc.length > 0 && ![ignoredDaemons containsObject:proc]) {
                                    if (![holders containsObject:proc]) [holders addObject:proc];
                                    if (prevCreators && ![prevCreators containsObject:creator] && ![newHolders containsObject:proc]) {
                                        [newHolders addObject:proc];
                                    }
                                    CFTypeRef subRef = IORegistryEntryCreateCFProperty(child, CFSTR("lastSubmittedTime"), kCFAllocatorDefault, 0);
                                    if (subRef && CFGetTypeID(subRef) == CFNumberGetTypeID()) {
                                        uint64_t subTime = 0;
                                        CFNumberGetValue((CFNumberRef)subRef, kCFNumberSInt64Type, &subTime);
                                        if (subTime > 0 && nowMat >= subTime && (nowMat - subTime) <= 15000000000ULL) {
                                            if (![activeQueues containsObject:proc]) [activeQueues addObject:proc];
                                        }
                                    }
                                    if (subRef) CFRelease(subRef);
                                }
                            }
                        }
                        if (creatorRef) CFRelease(creatorRef);
                        IOObjectRelease(child);
                    }
                    IOObjectRelease(childIter);
                }
            }
            CFRelease(classRef);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);

    if (prevCreatorsRef) *prevCreatorsRef = [curCreators copy];
    if (snapshotOnly) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (newHolders.count > 0)   [parts addObject:[NSString stringWithFormat:@"new=%@", [newHolders componentsJoinedByString:@", "]]];
    if (activeQueues.count > 0) [parts addObject:[NSString stringWithFormat:@"activeQ=%@", [activeQueues componentsJoinedByString:@", "]]];
    if (holders.count > 0)      [parts addObject:[NSString stringWithFormat:@"holders=%@", [holders componentsJoinedByString:@", "]]];
    return parts.count > 0 ? [parts componentsJoinedByString:@" | "] : @"none";
}

// Enumerate all CoreAudio input devices so non-default microphones selected inside VooV/Zoom are also detected
static BOOL is_any_microphone_active(void) {
    AudioObjectPropertyAddress devAddr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devAddr, 0, NULL, &dataSize) != noErr || dataSize == 0) {
        return NO;
    }
    int count = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID *devs = (AudioDeviceID *)malloc(dataSize);
    if (!devs) return NO;
    BOOL active = NO;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devAddr, 0, NULL, &dataSize, devs) == noErr) {
        for (int i = 0; i < count; i++) {
            AudioObjectPropertyAddress streamAddr = {
                kAudioDevicePropertyStreams,
                kAudioObjectPropertyScopeInput,
                kAudioObjectPropertyElementMain
            };
            UInt32 streamSize = 0;
            if (AudioObjectGetPropertyDataSize(devs[i], &streamAddr, 0, NULL, &streamSize) == noErr && streamSize > 0) {
                UInt32 isRunning = 0;
                UInt32 runSize = sizeof(isRunning);
                AudioObjectPropertyAddress runAddr = {
                    kAudioDevicePropertyDeviceIsRunningSomewhere,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                if (AudioObjectGetPropertyData(devs[i], &runAddr, 0, NULL, &runSize, &isRunning) == noErr && isRunning != 0) {
                    active = YES;
                    break;
                }
            }
        }
    }
    free(devs);
    return active;
}

// Bundle IDs of the processes that are capturing audio input right now (CoreAudio process objects, macOS 14+).
// Returns nil when the process list is unavailable so the caller can fall back to device-level detection.
static NSArray<NSString *> *bundle_ids_capturing_input(void) {
    AudioObjectPropertyAddress listAddr = {
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &listAddr, 0, NULL, &dataSize) != noErr) {
        return nil;
    }
    NSMutableArray<NSString *> *capturing = [NSMutableArray array];
    if (dataSize == 0) return capturing;
    AudioObjectID *procs = (AudioObjectID *)malloc(dataSize);
    if (!procs) return nil;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &listAddr, 0, NULL, &dataSize, procs) != noErr) {
        free(procs);
        return nil;
    }
    int count = dataSize / sizeof(AudioObjectID);
    for (int i = 0; i < count; i++) {
        AudioObjectPropertyAddress addr = {
            kAudioProcessPropertyIsRunningInput,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 isRunningInput = 0;
        UInt32 size = sizeof(isRunningInput);
        if (AudioObjectGetPropertyData(procs[i], &addr, 0, NULL, &size, &isRunningInput) != noErr || isRunningInput == 0) {
            continue;
        }
        CFStringRef bundleRef = NULL;
        size = sizeof(bundleRef);
        addr.mSelector = kAudioProcessPropertyBundleID;
        if (AudioObjectGetPropertyData(procs[i], &addr, 0, NULL, &size, &bundleRef) == noErr && bundleRef) {
            NSString *bundleId = (__bridge_transfer NSString *)bundleRef;
            if (bundleId.length > 0 && ![capturing containsObject:bundleId]) [capturing addObject:bundleId];
        }
    }
    free(procs);
    return capturing;
}

// Conference Acoustic Mode is entered only when a known call app is itself the process recording the microphone.
// `capturing` is the result of bundle_ids_capturing_input(); nil selects the legacy device-level heuristic.
static NSString *detect_active_meeting_call(NSArray<NSString *> *meetingBundles, NSString *frontBundleId, NSArray<NSString *> *capturing) {
    if (capturing) {
        // Prefix match so helper processes (com.google.Chrome.helper, ...) count as their parent app
        static NSArray<NSString *> *callApps = nil;
        static NSArray<NSString *> *browserApps = nil;
        if (!callApps) {
            callApps = @[
                @"com.tencent.xinWeChat", @"com.apple.FaceTime", @"com.apple.avconferenced",
                @"com.microsoft.teams2", @"com.tinyspeck.slackmacgap", @"com.electron.lark"
            ];
            browserApps = @[ @"com.google.Chrome", @"com.apple.Safari", @"com.apple.WebKit.GPU" ];
        }
        for (NSString *bundleId in capturing) {
            for (NSString *known in meetingBundles) {
                if ([bundleId hasPrefix:known]) {
                    return [NSRunningApplication runningApplicationsWithBundleIdentifier:known].firstObject.localizedName ?: known;
                }
            }
            for (NSString *known in callApps) {
                if ([bundleId hasPrefix:known]) {
                    return [known isEqualToString:@"com.tencent.xinWeChat"] ? @"WeChat 通话" : @"语音/视频通话";
                }
            }
            for (NSString *known in browserApps) {
                if ([bundleId hasPrefix:known]) return @"网页音视频通话";
            }
        }
        return nil;
    }

    if (!is_any_microphone_active()) {
        return nil;
    }
    for (NSString *bundleId in meetingBundles) {
        NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleId];
        if (apps.count > 0) {
            return apps.firstObject.localizedName ?: bundleId;
        }
    }
    static NSArray<NSString *> *voipApps = nil;
    if (!voipApps) {
        voipApps = @[
            @"com.tencent.xinWeChat", @"com.apple.FaceTime",
            @"com.microsoft.teams2", @"com.tinyspeck.slackmacgap",
            @"com.electron.lark"
        ];
    }
    for (NSString *bundleId in voipApps) {
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:bundleId].count > 0) {
            return [bundleId isEqualToString:@"com.tencent.xinWeChat"] ? @"WeChat 通话" : @"语音/视频通话";
        }
    }
    if ([frontBundleId isEqualToString:@"com.google.Chrome"] || [frontBundleId isEqualToString:@"com.apple.Safari"]) {
        return @"网页音视频通话";
    }
    return nil;
}

static NSString *matched_heavy_domain(NSString *url, NSArray<NSString *> *heavyDomains) {
    if (!url || url.length == 0) return nil;
    NSString *lower = [url lowercaseString];
    for (NSString *domain in heavyDomains) {
        if ([lower containsString:domain]) return domain;
    }
    return nil;
}

// Host part only (e.g. "www.linkedin.com"); paths and queries are never logged.
static NSString *url_host_only(NSString *url) {
    if (!url || url.length == 0) return nil;
    NSString *host = [[NSURL URLWithString:url] host];
    return host.length > 0 ? host : nil;
}

static double calc_5d_rpm(BOOL isLeftFan,
                          BOOL dgpuActive,
                          BOOL inMeetingMode,
                          int emergencyStreak,
                          double rawMaxCoreTemp,
                          double effTemp,
                          double heatsinkTemp,
                          double palmTemp,
                          double dgpuWatts,
                          int dgpuActivity,
                          double sysPower,
                          double minRPM,
                          double maxRPM,
                          double prevTarget,
                          const ThermalConfig *cfg) {
    // 1. Debounced emergency thermal bypass: >= 2 consecutive ticks at >= emergencyTemp, or immediately at emergencyTemp + 5C
    if (emergencyStreak >= 2 || rawMaxCoreTemp >= cfg->emergencyTemp + 5.0) {
        return maxRPM;
    }

    double startTemp = inMeetingMode ? cfg->startTempMeeting : (dgpuActive ? cfg->startTempDGPU : cfg->startTempIGPU);
    double midTemp   = inMeetingMode ? cfg->midTempMeeting   : (dgpuActive ? cfg->midTempDGPU   : cfg->midTempIGPU);
    double fullTemp  = cfg->fullTemp;
    double midRatio  = inMeetingMode ? cfg->midRatioMeeting  : cfg->midRatioNormal;

    double feedForwardC = 0.0;
    if (!inMeetingMode) {
        if (dgpuActive) {
            if (isLeftFan) {
                if (dgpuWatts > 8.0)   feedForwardC += fmin(6.0, (dgpuWatts - 8.0) * 0.20);
                if (dgpuActivity > 20) feedForwardC += fmin(3.0, (dgpuActivity - 20) * 0.04);
            } else {
                if (dgpuWatts > 14.0)  feedForwardC += fmin(3.5, (dgpuWatts - 14.0) * 0.12);
            }
        }
        if (sysPower > 48.0) {
            feedForwardC += fmin(3.5, (sysPower - 48.0) * 0.10);
        }
    }

    double t = effTemp + feedForwardC;
    double target = minRPM;
    if (t <= startTemp) {
        target = minRPM;
    } else if (t <= midTemp) {
        double ratio = (t - startTemp) / fmax(1.0, (midTemp - startTemp));
        double midRPM = minRPM + (maxRPM - minRPM) * midRatio;
        target = minRPM + (midRPM - minRPM) * (ratio * ratio);
    } else if (t < fullTemp) {
        double midRPM = minRPM + (maxRPM - minRPM) * midRatio;
        double ratio = (t - midTemp) / fmax(1.0, (fullTemp - midTemp));
        target = midRPM + (maxRPM - midRPM) * ratio;
    } else {
        target = maxRPM;
    }

    if (!inMeetingMode && dgpuActive && isLeftFan && dgpuWatts >= 9.5) {
        double dgpuFloor = (minRPM + 214.0) + fmin(950.0, (dgpuWatts - 9.5) * 32.0);
        if (target < dgpuFloor) target = dgpuFloor;
    }

    // 2. Heatpipe purge protection with negative feedback on palmrest sensor Ts0P (>35.5C lowers threshold)
    double basePurge = inMeetingMode ? cfg->purgeTempMeeting : (isLeftFan ? cfg->purgeTempLeft : cfg->purgeTempRight);
    double palmPenalty = (isfinite(palmTemp) && palmTemp > 35.5 && palmTemp < 55.0)
        ? fmin(2.5, (palmTemp - 35.5) * 0.6) : 0.0;
    double purgeThreshold = basePurge - palmPenalty;

    if (heatsinkTemp > purgeThreshold) {
        double soakFloor = minRPM + (heatsinkTemp - purgeThreshold) * (inMeetingMode ? 90.0 : 145.0);
        if (soakFloor > minRPM + 900.0) soakFloor = minRPM + 900.0;
        if (target < soakFloor) target = soakFloor;
    }

    // 3. Slew-rate limiting (if single-tick spike >=88C, allow faster +900 RPM step-up without slamming to 5616 RPM)
    double stepUpLimit = (emergencyStreak == 1) ? fmax(900.0, cfg->maxStepUpRPM * 2.0) : cfg->maxStepUpRPM;
    // The curve target follows the EMA, which lags a raw spike, so the spike itself has to request the fast step
    if (emergencyStreak == 1) target = fmax(target, prevTarget + stepUpLimit);
    if (prevTarget >= minRPM) {
        if (fabs(target - prevTarget) < cfg->deadbandRPM && target > minRPM) {
            target = prevTarget;
        } else if (target < prevTarget) {
            target = fmax(target, prevTarget - cfg->maxStepDownRPM);
        } else {
            target = fmin(target, prevTarget + stepUpLimit);
        }
    }
    return fmin(maxRPM, fmax(minRPM, target));
}

@interface AutoGPUAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenuItem *gpuStatusItem;
@property (strong) NSMenuItem *tempStatusItem;
@property (strong) NSMenuItem *pipeStatusItem;
@property (strong) NSMenuItem *fanStatusItem;
@property (strong) NSMenuItem *fanSmart5DItem;
@property (strong) NSMenuItem *fanAppleAutoItem;
@property (strong) NSMenuItem *fanFullBlastItem;
@property (strong) NSMenuItem *smartModeItem;
@property (strong) NSMenuItem *forceIGPUItem;
@property (strong) NSMenuItem *forceDGPUItem;
@property (assign) io_connect_t muxConn;
@property (assign) io_connect_t smcConn;
@property (assign) AutoGPUMode gpuMode;
@property (assign) FanControlMode fanMode;
@property (strong) dispatch_queue_t muxQueue;
@property (strong) dispatch_queue_t scriptQueue;
@property (strong) id<NSObject> activityToken;
@property (strong) dispatch_source_t sigTermSource;
@property (strong) dispatch_source_t sigIntSource;
@property (strong) NSArray<NSString *> *heavyDomains;
@property (strong) NSArray<NSString *> *meetingBundles;
@property (copy) NSString *cachedChromeURL;
@property (assign) BOOL scriptInFlight;
@property (assign) BOOL muxSwitchInFlight;
@property (assign) BOOL inSensorFaultState;
@property (assign) ThermalConfig thermalCfg;
@property (assign) double f0Min;
@property (assign) double f0Max;
@property (assign) double f1Min;
@property (assign) double f1Max;
@property (assign) int highLoadStreak;
@property (assign) int lowLoadStreak;
@property (assign) int emergencyStreak;
@property (assign) int configReloadTick;
@property (assign) int osThrottleStreak;
@property (assign) int osGuardLevel;
@property (assign) BOOL osThermalGuardEnabled;
@property (assign) double osFairFloorRatio;
@property (assign) double dgpuSustainWatts;
@property (assign) double dgpuHoldSeconds;
@property (assign) double dgpuHoldUntil;
@property (assign) double lastReturnToIGPUAt;
@property (assign) BOOL dgpuEpisodeActive;
@property (assign) BOOL displayWasAsleep;
@property (assign) double rescueGraceUntil;
@property (assign) uint64_t lastLoggedRawMuxState;
@property (assign) BOOL autoGPURequestedDGPU;
@property (assign) NSInteger lastChromeAEError;
@property (copy) NSString *lastMicCaptureDesc;
@property (copy) NSString *lastReason;
@property (copy) NSString *lastButtonTitle;
@property (assign) double emaCpuTemp;
@property (assign) double emaGpuTemp;
@property (assign) double lastTargetL;
@property (assign) double lastTargetR;
@property (assign) int lastAppliedL;
@property (assign) int lastAppliedR;
@property (assign) BOOL helperAuthed;
@property (assign) BOOL menuIsOpen;
@property (assign) BOOL inMeetingMode;
@property (strong) NSSet<NSString *> *lastAMDClientCreators;
@end

@implementation AutoGPUAppDelegate

- (void)loadConfigurationAndHardwareBounds {
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs registerDefaults:@{
        @"HeavyWebGLDomains": @[
            @"threejs.org", @"sketchfab.com", @"shadertoy.com",
            @"spline.design", @"figma.com/file", @"figma.com/design",
            @"earth.google.com"
        ],
        @"MeetingBundleIDs": @[
            @"com.tencent.tencentmeeting",
            @"us.zoom.xos"
        ],
        @"StartTempIGPU": @61.5,
        @"StartTempDGPU": @57.5,
        @"StartTempMeeting": @63.5,
        @"MidTempIGPU": @74.0,
        @"MidTempDGPU": @71.0,
        @"MidTempMeeting": @76.0,
        @"FullTemp": @86.0,
        @"EmergencyTemp": @88.0,
        @"MidRatioNormal": @0.46,
        @"MidRatioMeeting": @0.28,
        @"PurgeTempLeft": @51.5,
        @"PurgeTempRight": @53.5,
        @"PurgeTempMeeting": @55.5,
        @"MaxStepUpRPM": @800.0,
        @"MaxStepDownRPM": @170.0,
        @"DeadbandRPM": @55.0,
        @"DGPUSustainWatts": @28.0,
        @"OSThermalGuard": @YES,
        @"OSThermalFairFloorRatio": @0.25
    }];

    _heavyDomains   = [defs stringArrayForKey:@"HeavyWebGLDomains"] ?: @[];
    _meetingBundles = [defs stringArrayForKey:@"MeetingBundleIDs"]  ?: @[];

    _thermalCfg.startTempIGPU    = clamp_val([defs doubleForKey:@"StartTempIGPU"],    45.0, 75.0, 61.5);
    _thermalCfg.startTempDGPU    = clamp_val([defs doubleForKey:@"StartTempDGPU"],    45.0, 75.0, 57.5);
    _thermalCfg.startTempMeeting = clamp_val([defs doubleForKey:@"StartTempMeeting"], 50.0, 78.0, 63.5);
    _thermalCfg.midTempIGPU      = clamp_val([defs doubleForKey:@"MidTempIGPU"],      60.0, 85.0, 74.0);
    _thermalCfg.midTempDGPU      = clamp_val([defs doubleForKey:@"MidTempDGPU"],      60.0, 85.0, 71.0);
    _thermalCfg.midTempMeeting   = clamp_val([defs doubleForKey:@"MidTempMeeting"],   65.0, 85.0, 76.0);
    _thermalCfg.fullTemp         = clamp_val([defs doubleForKey:@"FullTemp"],         75.0, 95.0, 86.0);
    _thermalCfg.emergencyTemp    = clamp_val([defs doubleForKey:@"EmergencyTemp"],    80.0, 95.0, 88.0);
    _thermalCfg.midRatioNormal   = clamp_val([defs doubleForKey:@"MidRatioNormal"],   0.15, 0.85, 0.46);
    _thermalCfg.midRatioMeeting  = clamp_val([defs doubleForKey:@"MidRatioMeeting"],  0.15, 0.60, 0.28);
    _thermalCfg.purgeTempLeft    = clamp_val([defs doubleForKey:@"PurgeTempLeft"],    45.0, 65.0, 51.5);
    _thermalCfg.purgeTempRight   = clamp_val([defs doubleForKey:@"PurgeTempRight"],   45.0, 65.0, 53.5);
    _thermalCfg.purgeTempMeeting = clamp_val([defs doubleForKey:@"PurgeTempMeeting"], 48.0, 68.0, 55.5);
    _thermalCfg.maxStepUpRPM     = clamp_val([defs doubleForKey:@"MaxStepUpRPM"],     100.0, 2000.0, 800.0);
    _dgpuSustainWatts            = clamp_val([defs doubleForKey:@"DGPUSustainWatts"], 15.0, 80.0, 28.0);
    _thermalCfg.maxStepDownRPM   = clamp_val([defs doubleForKey:@"MaxStepDownRPM"],   50.0,  1000.0, 170.0);
    _thermalCfg.deadbandRPM      = clamp_val([defs doubleForKey:@"DeadbandRPM"],      10.0,  200.0,  55.0);
    _osThermalGuardEnabled       = [defs boolForKey:@"OSThermalGuard"];
    _osFairFloorRatio            = clamp_val([defs doubleForKey:@"OSThermalFairFloorRatio"], 0.0, 0.60, 0.25);

    double hwF0Min = read_smc_fast(_smcConn, "F0Mn");
    double hwF0Max = read_smc_fast(_smcConn, "F0Mx");
    double hwF1Min = read_smc_fast(_smcConn, "F1Mn");
    double hwF1Max = read_smc_fast(_smcConn, "F1Mx");

    _f0Min = (hwF0Min > 500.0 && hwF0Min < 4000.0) ? hwF0Min : 1836.0;
    _f0Max = (hwF0Max > 3000.0 && hwF0Max < 8000.0) ? hwF0Max : 5616.0;
    _f1Min = (hwF1Min > 500.0 && hwF1Min < 4000.0) ? hwF1Min : 1700.0;
    _f1Max = (hwF1Max > 3000.0 && hwF1Max < 8000.0) ? hwF1Max : 5200.0;
}

- (void)setupSignalAndWakeHandlers {
    _activityToken = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                    reason:@"AutoGPU Thermal and GPU Hardware Controller"];

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(handleSystemWake:)
                                                               name:NSWorkspaceDidWakeNotification
                                                             object:nil];

    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    __weak typeof(self) weakSelf = self;
    _sigTermSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_sigTermSource, ^{
        [weakSelf restoreAutoFansAndExit:@"SIGTERM"];
    });
    dispatch_resume(_sigTermSource);

    _sigIntSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_sigIntSource, ^{
        [weakSelf restoreAutoFansAndExit:@"SIGINT"];
    });
    dispatch_resume(_sigIntSource);
}

- (void)restoreAutoFansAndExit:(NSString *)sigName {
    log_autogpu(@"Received %@, restoring Apple Automatic fan control before exit", sigName);
    remove_heartbeat_file();
    [self applyFanModeString:"auto"];
    _exit(0);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    log_autogpu(@"Application terminating, restoring Apple Automatic fan control");
    remove_heartbeat_file();
    [self applyFanModeString:"auto"];
}

- (void)handleSystemWake:(NSNotification *)note {
    log_autogpu(@"System woke from sleep, resetting fan applied state and re-evaluating");
    _lastAppliedL = -1;
    _lastAppliedR = -1;
    _highLoadStreak = 0;
    _rescueGraceUntil = [[NSProcessInfo processInfo] systemUptime] + 30.0;
    [self tick];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _muxQueue    = dispatch_queue_create("com.ericzhu.autogpu.mux", DISPATCH_QUEUE_SERIAL);
    _scriptQueue = dispatch_queue_create("com.ericzhu.autogpu.script", DISPATCH_QUEUE_SERIAL);

    io_service_t muxSvc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleMuxControl"));
    if (muxSvc) {
        if (IOServiceOpen(muxSvc, mach_task_self(), 0, &_muxConn) == kIOReturnSuccess) {
            IOConnectCallScalarMethod(_muxConn, 0, NULL, 0, NULL, NULL);
        }
        IOObjectRelease(muxSvc);
    }

    io_service_t smcSvc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (smcSvc) {
        if (IOServiceOpen(smcSvc, mach_task_self(), 0, &_smcConn) != kIOReturnSuccess) {
            _smcConn = 0;
        }
        IOObjectRelease(smcSvc);
    }

    [self loadConfigurationAndHardwareBounds];
    [self setupSignalAndWakeHandlers];

    struct stat st;
    _helperAuthed = (stat("/usr/local/bin/smc-fan-helper", &st) == 0 && st.st_uid == 0 && (st.st_mode & S_ISUID));

    _gpuMode = AutoGPUModeSmart;
    _fanMode = FanModeSmart5D;
    _lastReason = @"日常省电巡航";
    double initCpu = read_smc_fast(_smcConn, "TCXC");
    double initGpu = read_smc_fast(_smcConn, "TG0P");
    _emaCpuTemp = (initCpu > 15.0 && initCpu < 115.0) ? initCpu : 52.0;
    _emaGpuTemp = (initGpu > 15.0 && initGpu < 115.0) ? initGpu : 46.0;
    _lastTargetL = _f0Min;
    _lastTargetR = _f1Min;
    _lastAppliedL = -1;
    _lastAppliedR = -1;
    _dgpuHoldSeconds = 60.0;
    query_amd_accel_holders(&_lastAMDClientCreators, YES);

    log_autogpu(@"AutoGPU v3.5 started (SMC=%s, HelperAuthed=%s, F0=%.0f..%.0f, F1=%.0f..%.0f, OSThermalGuard=%s, CPU_Speed_Limit=%d, thermalState=%ld)",
                _smcConn ? "OK" : "FAIL", _helperAuthed ? "YES" : "NO", _f0Min, _f0Max, _f1Min, _f1Max,
                _osThermalGuardEnabled ? "ON" : "OFF", read_cpu_speed_limit(), (long)[[NSProcessInfo processInfo] thermalState]);

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;

    _gpuStatusItem  = [[NSMenuItem alloc] initWithTitle:@"当前显卡: 检测中..." action:nil keyEquivalent:@""];
    _tempStatusItem = [[NSMenuItem alloc] initWithTitle:@"核心温度: 检测中..." action:nil keyEquivalent:@""];
    _pipeStatusItem = [[NSMenuItem alloc] initWithTitle:@"热管与功耗: 检测中..." action:nil keyEquivalent:@""];
    _fanStatusItem  = [[NSMenuItem alloc] initWithTitle:@"双风扇转速: 检测中..." action:nil keyEquivalent:@""];
    [menu addItem:_gpuStatusItem];
    [menu addItem:_tempStatusItem];
    [menu addItem:_pipeStatusItem];
    [menu addItem:_fanStatusItem];
    [menu addItem:[NSMenuItem separatorItem]];

    _fanSmart5DItem = [[NSMenuItem alloc] initWithTitle:@"🧠 5D 显卡联动温控 (含VooV/微信会议降噪)" action:@selector(selectFanSmart:) keyEquivalent:@""];
    _fanSmart5DItem.target = self;
    _fanAppleAutoItem = [[NSMenuItem alloc] initWithTitle:@"🍎 苹果原厂默认风控 (Apple Automatic)" action:@selector(selectFanApple:) keyEquivalent:@""];
    _fanAppleAutoItem.target = self;
    NSString *fullTitle = [NSString stringWithFormat:@"🌪️ 双风扇强力满速 (%.0f / %.0f RPM)", _f0Max, _f1Max];
    _fanFullBlastItem = [[NSMenuItem alloc] initWithTitle:fullTitle action:@selector(selectFanFull:) keyEquivalent:@""];
    _fanFullBlastItem.target = self;
    [menu addItem:_fanSmart5DItem];
    [menu addItem:_fanAppleAutoItem];
    [menu addItem:_fanFullBlastItem];
    [menu addItem:[NSMenuItem separatorItem]];

    _smartModeItem = [[NSMenuItem alloc] initWithTitle:@"🤖 显卡智能自动切换 (3D开独显/会议锁核显)" action:@selector(selectSmart:) keyEquivalent:@""];
    _smartModeItem.target = self;
    _forceIGPUItem = [[NSMenuItem alloc] initWithTitle:@"🟢 强制锁死核显 (Intel UHD 630)" action:@selector(selectIGPU:) keyEquivalent:@""];
    _forceIGPUItem.target = self;
    _forceDGPUItem = [[NSMenuItem alloc] initWithTitle:@"⚡️ 强制锁死独显 (AMD 5500M)" action:@selector(selectDGPU:) keyEquivalent:@""];
    _forceDGPUItem.target = self;

    [menu addItem:_smartModeItem];
    [menu addItem:_forceIGPUItem];
    [menu addItem:_forceDGPUItem];
    _statusItem.menu = menu;

    [self tick];

    // Common modes, not the default mode: a default-mode timer stops firing while the status menu is open,
    // which froze fan control and let the heartbeat go stale (watchdog fired after 10s of an open menu)
    NSTimer *timer = [NSTimer timerWithTimeInterval:2.5 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    timer.tolerance = 0.8;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)pollChromeURLAsync {
    if (_scriptInFlight) return;
    _scriptInFlight = YES;
    dispatch_async(_scriptQueue, ^{
        BOOL timedOut = NO;
        NSInteger errCode = 0;
        NSString *fetched = query_chrome_url_ae(&timedOut, &errCode);
        dispatch_async(dispatch_get_main_queue(), ^{
            // Preserve cachedChromeURL if Chrome timed out while rendering heavy 3D content
            if (!timedOut) {
                self.cachedChromeURL = fetched;
            }
            // "No window / no such object" is normal when Chrome has no window open; anything else means the
            // 3D-domain feature is not working, so record it once per change instead of failing silently
            NSInteger reportable = (timedOut || errCode == errAENoSuchObject || errCode == errAEIllegalIndex) ? 0 : errCode;
            if (reportable != self.lastChromeAEError) {
                self.lastChromeAEError = reportable;
                if (reportable == errAEEventNotPermitted) {
                    log_autogpu(@"Chrome URL query denied (-1743): allow AutoGPU under System Settings > Privacy & Security > Automation, 3D-domain switching is inactive until then");
                } else if (reportable != 0) {
                    log_autogpu(@"Chrome URL query failing with AppleEvent error %ld, 3D-domain switching is inactive", (long)reportable);
                } else {
                    log_autogpu(@"Chrome URL query working again");
                }
            }
            self.scriptInFlight = NO;
        });
    });
}

- (void)applyFanRPMLeft:(int)leftRPM right:(int)rightRPM {
    if (!_helperAuthed) return;
    touch_heartbeat_file();
    if (abs(leftRPM - _lastAppliedL) < 25 && abs(rightRPM - _lastAppliedR) < 25) {
        return;
    }
    _lastAppliedL = leftRPM;
    _lastAppliedR = rightRPM;
    char lbuf[16], rbuf[16];
    snprintf(lbuf, sizeof(lbuf), "%d", leftRPM);
    snprintf(rbuf, sizeof(rbuf), "%d", rightRPM);
    char *argv[] = { "/usr/local/bin/smc-fan-helper", lbuf, rbuf, NULL };
    pid_t pid;
    if (posix_spawn(&pid, "/usr/local/bin/smc-fan-helper", NULL, NULL, argv, environ) == 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

- (void)applyFanModeString:(const char *)modeStr {
    if (!_helperAuthed) return;
    if (strcmp(modeStr, "auto") == 0) {
        remove_heartbeat_file();
    } else {
        touch_heartbeat_file();
    }
    _lastAppliedL = -1;
    _lastAppliedR = -1;
    char *argv[] = { "/usr/local/bin/smc-fan-helper", (char *)modeStr, NULL };
    pid_t pid;
    if (posix_spawn(&pid, "/usr/local/bin/smc-fan-helper", NULL, NULL, argv, environ) == 0) {
        int status;
        waitpid(pid, &status, 0);
    }
}

- (void)switchToDiscreteWithReason:(NSString *)reason {
    if (_muxSwitchInFlight || get_current_gpu(_muxConn) == 0) return;
    _muxSwitchInFlight = YES;
    _autoGPURequestedDGPU = YES;
    log_autogpu(@"Switching GPU -> AMD 5500M (reason: %@)", reason);
    dispatch_async(_muxQueue, ^{
        if (get_current_gpu(self.muxConn) != 0) {
            set_gpu_state(self.muxConn, 1, 1);
            set_gpu_state(self.muxConn, 5, 0);
            set_gpu_state(self.muxConn, 4, 1);
            sleep(1);
            set_gpu_state(self.muxConn, 4, 0);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.muxSwitchInFlight = NO;
        });
    });
}

- (void)switchToIntegratedWithReason:(NSString *)reason {
    if (_muxSwitchInFlight || get_current_gpu(_muxConn) == 1) return;
    _muxSwitchInFlight = YES;
    log_autogpu(@"Switching GPU -> Intel UHD 630 (reason: %@)", reason);
    dispatch_async(_muxQueue, ^{
        if (get_current_gpu(self.muxConn) != 1) {
            set_gpu_state(self.muxConn, 4, 0);
            sleep(1);
            set_gpu_state(self.muxConn, 2, 0);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.muxSwitchInFlight = NO;
        });
    });
}

- (void)menuWillOpen:(NSMenu *)menu {
    _menuIsOpen = YES;
    [self refreshDetailedMenuItems];
}

- (void)menuDidClose:(NSMenu *)menu {
    _menuIsOpen = NO;
}

- (void)refreshDetailedMenuItems {
    uint64_t currentGpu = get_current_gpu(_muxConn);
    double cpuNow = read_smc_fast(_smcConn, "TCXC");
    if (cpuNow < 15.0) cpuNow = read_smc_fast(_smcConn, "TC0P");
    double tg0p = read_smc_fast(_smcConn, "TG0P");
    double th1h = read_smc_fast(_smcConn, "Th1H");
    double th2h = read_smc_fast(_smcConn, "Th2H");
    double ts0p = read_smc_fast(_smcConn, "Ts0P");
    double f0Ac = read_smc_fast(_smcConn, "F0Ac");
    double f1Ac = read_smc_fast(_smcConn, "F1Ac");
    double pstr = read_smc_fast(_smcConn, "PSTR");
    double pg0r = read_smc_fast(_smcConn, "PG0R");
    GPUTelemetry gt = read_gpu_telemetry(currentGpu == 0);

    double trueGpuTemp = (currentGpu == 0 && gt.dgpuDieTemp > 20) ? fmax(tg0p, (double)gt.dgpuDieTemp) : tg0p;
    double dgpuWatts   = (pg0r > (double)gt.dgpuPowerW) ? pg0r : (double)gt.dgpuPowerW;

    _gpuStatusItem.title = (currentGpu == 0)
        ? [NSString stringWithFormat:@"⚡️ 独显运行中: AMD 5500M (%.1fW | 负载%d%%) · %@", dgpuWatts, gt.dgpuActivity, _lastReason]
        : [NSString stringWithFormat:@"🟢 核显运行中: Intel UHD 630 (负载%d%%) · %@", gt.igpuUtil, _lastReason];

    _tempStatusItem.title = (currentGpu == 0)
        ? [NSString stringWithFormat:@"🌡️ CPU: %.1f°C (平滑%.1f°C) | 独显Die: %.0f°C (掌托%.1f°C)", cpuNow, _emaCpuTemp, trueGpuTemp, ts0p]
        : [NSString stringWithFormat:@"🌡️ CPU: %.1f°C (平滑%.1f°C) | 独显休眠: %.1f°C (掌托%.1f°C)", cpuNow, _emaCpuTemp, tg0p, ts0p];

    _pipeStatusItem.title = [NSString stringWithFormat:@"❄️ 热管: 左(GPU侧) %.1f°C / 右(CPU侧) %.1f°C | 整机: %.1fW", th1h, th2h, pstr];

    NSString *syncTag = _inMeetingMode ? @"🎙️会议降噪护航" : ((currentGpu == 0) ? @"⚡️独显预冷联动" : @"🟢核显静默防尘");
    _fanStatusItem.title  = [NSString stringWithFormat:@"🌀 风扇: 左 %.0f / 右 %.0f RPM (%@)", f0Ac, f1Ac, syncTag];

    _fanSmart5DItem.state   = (_fanMode == FanModeSmart5D)   ? NSControlStateValueOn : NSControlStateValueOff;
    _fanAppleAutoItem.state = (_fanMode == FanModeAppleAuto) ? NSControlStateValueOn : NSControlStateValueOff;
    _fanFullBlastItem.state = (_fanMode == FanModeFullBlast) ? NSControlStateValueOn : NSControlStateValueOff;

    _smartModeItem.state = (_gpuMode == AutoGPUModeSmart)           ? NSControlStateValueOn : NSControlStateValueOff;
    _forceIGPUItem.state = (_gpuMode == AutoGPUModeForceIntegrated) ? NSControlStateValueOn : NSControlStateValueOff;
    _forceDGPUItem.state = (_gpuMode == AutoGPUModeForceDiscrete)   ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)selectFanSmart:(id)sender { log_autogpu(@"User selected FanModeSmart5D"); _fanMode = FanModeSmart5D; _lastAppliedL = -1; [self tick]; }
- (void)selectFanApple:(id)sender { log_autogpu(@"User selected FanModeAppleAuto"); _fanMode = FanModeAppleAuto; [self applyFanModeString:"auto"]; [self tick]; }
- (void)selectFanFull:(id)sender  { log_autogpu(@"User selected FanModeFullBlast"); _fanMode = FanModeFullBlast; [self applyFanModeString:"full"]; [self tick]; }

- (void)selectSmart:(id)sender {
    log_autogpu(@"User selected AutoGPUModeSmart");
    self.gpuMode = AutoGPUModeSmart;
    self.lastReason = @"智能自动巡航";
    [self tick];
}
- (void)selectIGPU:(id)sender {
    log_autogpu(@"User selected AutoGPUModeForceIntegrated");
    self.gpuMode = AutoGPUModeForceIntegrated;
    self.lastReason = @"手动锁定核显";
    [self switchToIntegratedWithReason:@"手动锁定核显"];
}
- (void)selectDGPU:(id)sender {
    log_autogpu(@"User selected AutoGPUModeForceDiscrete");
    self.gpuMode = AutoGPUModeForceDiscrete;
    self.lastReason = @"手动锁定独显";
    [self switchToDiscreteWithReason:@"手动锁定独显"];
}

- (void)tick {
    BOOL periodicReassert = NO;
    if (++_configReloadTick >= 12) {
        _configReloadTick = 0;
        [self loadConfigurationAndHardwareBounds];
        periodicReassert = YES;
    }

    double cpuNow = read_smc_fast(_smcConn, "TCXC");
    if (cpuNow < 15.0) cpuNow = read_smc_fast(_smcConn, "TC0P");
    double tg0p   = read_smc_fast(_smcConn, "TG0P");
    double th1h   = read_smc_fast(_smcConn, "Th1H");
    double th2h   = read_smc_fast(_smcConn, "Th2H");
    double ts0p   = read_smc_fast(_smcConn, "Ts0P");
    double pstr   = read_smc_fast(_smcConn, "PSTR");

    // De-duplicated fail-safe sensor validation
    BOOL cpuValid = isfinite(cpuNow) && cpuNow > 15.0 && cpuNow < 120.0;
    BOOL gpuValid = isfinite(tg0p)   && tg0p   > 10.0 && tg0p   < 120.0;
    if (!_smcConn || !cpuValid || !gpuValid) {
        if (!_inSensorFaultState) {
            _inSensorFaultState = YES;
            log_autogpu(@"Sensor read failure (cpu=%.1f, gpu=%.1f), restoring Apple Automatic fan control", cpuNow, tg0p);
            [self applyFanModeString:"auto"];
        }
        return;
    } else if (_inSensorFaultState) {
        _inSensorFaultState = NO;
        _lastAppliedL = -1;
        _lastAppliedR = -1;
        log_autogpu(@"Sensor readings recovered (cpu=%.1f, gpu=%.1f), resuming fan control", cpuNow, tg0p);
    }

    if (!isfinite(th1h) || th1h < 15.0 || th1h > 110.0) th1h = 42.0;
    if (!isfinite(th2h) || th2h < 15.0 || th2h > 110.0) th2h = 42.0;
    if (!isfinite(pstr) || pstr < 0.0  || pstr > 150.0) pstr = 18.0;

    uint64_t currentGpu = get_current_gpu(_muxConn);
    GPUTelemetry gt = read_gpu_telemetry(currentGpu == 0);
    double pg0r = (currentGpu == 0) ? read_smc_fast(_smcConn, "PG0R") : 0.08;
    double dgpuWatts = (currentGpu == 0) ? fmax(pg0r, (double)gt.dgpuPowerW) : 0.08;

    NSRunningApplication *frontApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    NSString *frontBundleId = [frontApp bundleIdentifier] ?: @"";
    NSArray<NSString *> *micCapturing = bundle_ids_capturing_input();
    NSString *meetingApp = detect_active_meeting_call(_meetingBundles, frontBundleId, micCapturing);
    BOOL prevMeeting = _inMeetingMode;
    _inMeetingMode = (meetingApp != nil);
    if (_inMeetingMode != prevMeeting) {
        log_autogpu(@"Conference Acoustic Mode %s (%@)", _inMeetingMode ? "ENABLED" : "DISABLED", meetingApp ?: @"None");
    }
    NSString *micDesc = [micCapturing componentsJoinedByString:@", "] ?: @"";
    if (![micDesc isEqualToString:_lastMicCaptureDesc ?: @""]) {
        _lastMicCaptureDesc = micDesc;
        if (micDesc.length > 0 && !meetingApp) {
            log_autogpu(@"Microphone in use by %@ (not a known call app; add its bundle ID to MeetingBundleIDs if it should trigger Conference Acoustic Mode)", micDesc);
        }
    }

    BOOL extDisplay = has_physical_external_display();
    BOOL wantDiscrete = NO;

    // dGPU episode tracking. On this 5500M "GPU Activity(%)" reads 24-91% on an idle desktop, so it cannot tell
    // real work from compositing. Each episode gets a timed hold instead; if the dGPU comes back within 2 min
    // of being released (iGPU overloaded again, or macOS/an app pulled it in) the hold doubles, up to 15 min,
    // which bounds mux flapping. A quiet 10 min on the iGPU resets the hold to 60s.
    double nowUptime = [[NSProcessInfo processInfo] systemUptime];
    if (currentGpu == 0 && !_dgpuEpisodeActive) {
        _dgpuEpisodeActive = YES;
        if (_lastReturnToIGPUAt > 0.0 && nowUptime - _lastReturnToIGPUAt < 120.0) {
            _dgpuHoldSeconds = fmin(900.0, _dgpuHoldSeconds * 2.0);
        } else if (_lastReturnToIGPUAt == 0.0 || nowUptime - _lastReturnToIGPUAt > 600.0) {
            _dgpuHoldSeconds = 60.0;
        }
        _dgpuHoldUntil = nowUptime + _dgpuHoldSeconds;
        if (_autoGPURequestedDGPU) {
            query_amd_accel_holders(&_lastAMDClientCreators, YES);
            log_autogpu(@"dGPU active (requested by AutoGPU), holding for %.0fs before trying the iGPU again", _dgpuHoldSeconds);
        } else {
            NSString *amdClients = query_amd_accel_holders(&_lastAMDClientCreators, NO);
            log_autogpu(@"dGPU active (pulled in by macOS or an app; AMD clients: %@), holding for %.0fs before trying the iGPU again",
                        amdClients, _dgpuHoldSeconds);
        }
    } else if (currentGpu != 0 && _dgpuEpisodeActive && !_muxSwitchInFlight) {
        _dgpuEpisodeActive = NO;
        _autoGPURequestedDGPU = NO;
        _lastReturnToIGPUAt = nowUptime;
        query_amd_accel_holders(&_lastAMDClientCreators, YES);
    }

    if (g_rawMuxState > 1 && g_rawMuxState != _lastLoggedRawMuxState) {
        _lastLoggedRawMuxState = g_rawMuxState;
        log_autogpu(@"Mux reports state %llu (treated as integrated)", (unsigned long long)g_rawMuxState);
    }

    // While the panel is off (display sleep, dark wake) nothing is on screen to decide for: send no mux commands
    // and no Chrome queries. Waking redraws everything at once, so the iGPU-overload rescue gets a 30s grace period.
    BOOL displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) ? YES : NO;
    if (_displayWasAsleep && !displayAsleep) {
        _highLoadStreak = 0;
        _rescueGraceUntil = nowUptime + 30.0;
    }
    _displayWasAsleep = displayAsleep;

    if (displayAsleep) {
        _highLoadStreak = 0;
        _lowLoadStreak = 0;
        wantDiscrete = (currentGpu == 0);
    } else if (_gpuMode == AutoGPUModeForceIntegrated) {
        if (!extDisplay && currentGpu != 1) [self switchToIntegratedWithReason:@"手动锁定核显"];
        wantDiscrete = extDisplay;
    } else if (_gpuMode == AutoGPUModeForceDiscrete) {
        if (currentGpu != 0) [self switchToDiscreteWithReason:@"手动锁定独显"];
        wantDiscrete = YES;
    } else if (extDisplay) {
        _lowLoadStreak = 0;
        wantDiscrete = YES;
        self.lastReason = @"外接物理显示器直连独显";
        if (currentGpu != 0) [self switchToDiscreteWithReason:self.lastReason];
    } else {
        BOOL chromeIsRunning = ([NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.google.Chrome"].count > 0);
        BOOL chromeIsFront   = [frontBundleId isEqualToString:@"com.google.Chrome"];
        if (!chromeIsRunning) {
            _cachedChromeURL = nil;
        } else if (chromeIsFront || currentGpu == 0) {
            [self pollChromeURLAsync];
        }
        NSString *matchedDomain = chromeIsRunning ? matched_heavy_domain(_cachedChromeURL, _heavyDomains) : nil;

        int utilThreshold = _inMeetingMode ? 82 : 55;
        int streakNeeded  = _inMeetingMode ? 4  : 2;
        if (gt.igpuUtil >= utilThreshold && nowUptime >= _rescueGraceUntil) _highLoadStreak++; else _highLoadStreak = 0;

        // Stay on the dGPU while it draws real 3D/compute power (idle and compositing sit at 11-18W here) or while
        // the episode's timed hold is running; active in all modes to prevent oscillation
        BOOL dgpuUnderRealLoad  = (dgpuWatts >= _dgpuSustainWatts);
        BOOL dgpuSustainingLoad = (currentGpu == 0) && (dgpuUnderRealLoad || nowUptime < _dgpuHoldUntil);

        if (matchedDomain != nil && !_inMeetingMode) {
            _lowLoadStreak = 0;
            wantDiscrete = YES;
            self.lastReason = [NSString stringWithFormat:@"3D网页加速 (%@)", matchedDomain];
            if (currentGpu != 0) [self switchToDiscreteWithReason:self.lastReason];
        } else if (_highLoadStreak >= streakNeeded) {
            _lowLoadStreak = 0;
            wantDiscrete = YES;
            self.lastReason = [NSString stringWithFormat:@"核显高负载救援 (%d%%)", gt.igpuUtil];
            if (currentGpu != 0) {
                NSString *host = chromeIsFront ? url_host_only(_cachedChromeURL) : nil;
                log_autogpu(@"iGPU overload at %d%%: front app %@%@", gt.igpuUtil,
                            frontApp.localizedName ?: (frontBundleId.length ? frontBundleId : @"unknown"),
                            host ? [NSString stringWithFormat:@" (%@)", host] : @"");
                [self switchToDiscreteWithReason:self.lastReason];
            }
        } else if (dgpuSustainingLoad) {
            _lowLoadStreak = 0;
            wantDiscrete = YES;
            self.lastReason = dgpuUnderRealLoad
                ? [NSString stringWithFormat:@"独显负载维持中 (%.1fW)", dgpuWatts]
                : [NSString stringWithFormat:@"独显保持中 (还剩 %.0f 秒 | %.1fW)", fmax(0.0, _dgpuHoldUntil - nowUptime), dgpuWatts];
        } else {
            _lowLoadStreak++;
            if (_lowLoadStreak >= 6) {
                wantDiscrete = NO;
                self.lastReason = _inMeetingMode
                    ? [NSString stringWithFormat:@"%@ 会议锁核显省电", meetingApp]
                    : @"日常省电巡航 (0.08W 独显休眠)";
                if (currentGpu != 1) [self switchToIntegratedWithReason:self.lastReason];
            } else {
                wantDiscrete = (currentGpu == 0);
            }
        }
    }

    BOOL dgpuActive = (currentGpu == 0) || wantDiscrete;
    double trueGpuTemp = (dgpuActive && gt.dgpuDieTemp > 20 && gt.dgpuDieTemp < 115)
        ? fmax(tg0p, (double)gt.dgpuDieTemp) : tg0p;
    double rawMaxCoreTemp = dgpuActive ? fmax(cpuNow, trueGpuTemp) : cpuNow;

    if (rawMaxCoreTemp >= _thermalCfg.emergencyTemp) {
        _emergencyStreak++;
    } else {
        _emergencyStreak = 0;
    }

    // OS thermal-pressure guard. Level 2: macOS is already throttling the CPU (thermalState >= Serious, or
    // CPU_Speed_Limit < 100 outside Low Power Mode) for 2 consecutive ticks -> full cooling.
    // Level 1: thermalState == Fair -> modest RPM floor. Catches zones this curve does not read.
    int cpuSpeedLimit = read_cpu_speed_limit();
    NSProcessInfoThermalState osThermal = [[NSProcessInfo processInfo] thermalState];
    BOOL osThrottling = (osThermal >= NSProcessInfoThermalStateSerious)
        || (cpuSpeedLimit < 100 && ![[NSProcessInfo processInfo] isLowPowerModeEnabled]);
    _osThrottleStreak = osThrottling ? _osThrottleStreak + 1 : 0;
    int osGuardLevel = 0;
    if (_osThermalGuardEnabled) {
        if (_osThrottleStreak >= 2) osGuardLevel = 2;
        else if (osThermal >= NSProcessInfoThermalStateFair) osGuardLevel = 1;
    }
    if (osGuardLevel != _osGuardLevel) {
        _osGuardLevel = osGuardLevel;
        log_autogpu(@"OS thermal guard level %d (thermalState=%ld, CPU_Speed_Limit=%d%%, cpu=%.1fC, TB-left=%.0fC, TB-right=%.0fC)",
                    osGuardLevel, (long)osThermal, cpuSpeedLimit, cpuNow,
                    read_smc_fast(_smcConn, "TTLD"), read_smc_fast(_smcConn, "TTRD"));
    }

    _emaCpuTemp = 0.22 * cpuNow + 0.78 * _emaCpuTemp;
    _emaGpuTemp = 0.28 * trueGpuTemp + 0.72 * _emaGpuTemp;

    if (_helperAuthed && (_fanMode == FanModeSmart5D || _fanMode == FanModeFullBlast)) {
        // Watchdog / external reset recovery check: read F0Md & F1Md and re-assert if != 1
        double f0Md = read_smc_fast(_smcConn, "F0Md");
        double f1Md = read_smc_fast(_smcConn, "F1Md");
        // A failed read (-999/-998) is "unknown", not "mode lost"
        BOOL modeReadable = (f0Md >= 0.0 && f0Md <= 3.0 && f1Md >= 0.0 && f1Md <= 3.0);
        BOOL modeLost = modeReadable && ((int)round(f0Md) != 1 || (int)round(f1Md) != 1);
        if (modeLost) {
            log_autogpu(@"Detected F0Md=%.0f F1Md=%.0f (watchdog or external reset), re-asserting fan mode", f0Md, f1Md);
        }
        // periodicReassert: one helper call every ~30s re-runs its watchdog check, so forced mode can never be
        // left without a watchdog for longer than that even if the watchdog exited in a race with a helper call
        if (modeLost || periodicReassert) {
            _lastAppliedL = -1;
            _lastAppliedR = -1;
            if (_fanMode == FanModeFullBlast) {
                [self applyFanModeString:"full"];
            }
        }
    }

    if (_helperAuthed && _fanMode == FanModeSmart5D) {
        double effLeft  = dgpuActive
            ? fmax(_emaCpuTemp, fmax(_emaGpuTemp + 2.5, th1h + 6.5))
            : fmax(_emaCpuTemp, th1h + 6.0);
        double effRight = fmax(_emaCpuTemp, th2h + 6.5);

        int emergencyLevel = (osGuardLevel == 2) ? 2 : _emergencyStreak;
        _lastTargetL = calc_5d_rpm(YES, dgpuActive, _inMeetingMode, emergencyLevel, rawMaxCoreTemp, effLeft,  th1h, ts0p, dgpuWatts, gt.dgpuActivity, pstr, _f0Min, _f0Max, _lastTargetL, &_thermalCfg);
        _lastTargetR = calc_5d_rpm(NO,  dgpuActive, _inMeetingMode, emergencyLevel, rawMaxCoreTemp, effRight, th2h, ts0p, dgpuWatts, gt.dgpuActivity, pstr, _f1Min, _f1Max, _lastTargetR, &_thermalCfg);
        if (osGuardLevel == 1) {
            _lastTargetL = fmax(_lastTargetL, _f0Min + (_f0Max - _f0Min) * _osFairFloorRatio);
            _lastTargetR = fmax(_lastTargetR, _f1Min + (_f1Max - _f1Min) * _osFairFloorRatio);
        }

        [self applyFanRPMLeft:(int)round(_lastTargetL) right:(int)round(_lastTargetR)];
    } else if (_helperAuthed && _fanMode == FanModeFullBlast) {
        touch_heartbeat_file();
    }

    NSString *gpuIcon = (currentGpu == 0) ? @"⚡️" : @"🟢";
    double displayTemp = (currentGpu == 0) ? fmax(_emaCpuTemp, _emaGpuTemp) : _emaCpuTemp;
    NSString *newTitle = [NSString stringWithFormat:@"%@%.0f°C", gpuIcon, displayTemp];
    if (![_lastButtonTitle isEqualToString:newTitle]) {
        _lastButtonTitle = newTitle;
        _statusItem.button.title = newTitle;
    }

    if (_menuIsOpen) {
        [self refreshDetailedMenuItems];
    }
}
@end

int main(int argc, const char * argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AutoGPUAppDelegate *del = [[AutoGPUAppDelegate alloc] init];
        app.delegate = del;
        [app run];
    }
    return 0;
}
