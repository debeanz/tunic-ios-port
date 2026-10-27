/*
 * UnityShimC.c - C-level stand-ins for the macOS-only APIs Tunic's Unity 2020.3 Mac player (UnityPlayer.dylib) and its
 * plugins (fmodstudio, InControlNative) import but iOS does not provide. Same rules as MacShimC.c: header-free, own
 * typedefs, everything fails gracefully. The list comes from checking every import against the iOS 16.5 SDK stubs.
 *
 *   IOKit HID / power / registry   -> no devices, no power sources (controllers come through GameController)
 *   Carbon keyboard layouts        -> a US layout with no translation data (keyboards come through GameController)
 *   CoreServices (Gestalt, ...)    -> Mac-like answers; its re-exported libm calls forward to libsystem_m
 *   OpenGL (CGL, gl*)              -> "no OpenGL" (Unity renders with Metal)
 *   CoreGraphics display extras    -> the rest of the display calls MacShimC.c doesn't answer
 *   CoreAudio HAL                  -> one stereo output device (FMOD's Mac output asks for it), see "audio" below
 *   AudioUnit                      -> AudioToolbox, with the Mac HAL output unit swapped for iOS RemoteIO
 *   Security keychain calls        -> errSecUnimplemented
 *   syslog$DARWIN_EXTSN            -> vsyslog
 */
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

extern void *dlopen(const char *path, int mode); extern void *dlsym(void *h, const char *name);
#define RTLD_LAZY 0x1
#define RTLD_NOLOAD 0x10
extern void *memset(void *, int, size_t); extern void *memcpy(void *, const void *, size_t);
extern int snprintf(char *, size_t, const char *, ...);
extern void vsyslog(int pri, const char *fmt, va_list ap);
extern uint64_t clock_gettime_nsec_np(int clock_id);
#define CLOCK_UPTIME_RAW 8

/* implemented in MacShim.m / UnityShim.m */
extern void MacShimScreenInfo(double *w_points, double *h_points, double *scale, double *max_fps);
extern void MacShimLogC(const char *what, const char *detail);
extern double MacShimAudioSampleRate(void);          /* AVAudioSession's hardware rate (activates the session) */
extern void MacShimAudioSetBufferFrames(uint32_t frames);

/* CoreFoundation, declared by hand */
typedef const void *CFTypeRef;
extern CFTypeRef CFRetain(CFTypeRef cf);
extern CFTypeRef CFStringCreateWithCString(const void *alloc, const char *s, uint32_t enc);
extern CFTypeRef CFSetCreate(const void *alloc, const void **values, long n, const void *callbacks);
extern CFTypeRef CFArrayCreate(const void *alloc, const void **values, long n, const void *callbacks);
extern CFTypeRef CFDictionaryCreateMutable(const void *alloc, long cap, const void *kcb, const void *vcb);
typedef struct { long version; void *info; const void *(*retain)(const void *); void (*release)(const void *);
                 CFTypeRef (*copyDescription)(const void *); unsigned char (*equal)(const void *, const void *);
                 unsigned long (*hash)(const void *); void (*schedule)(void *, void *, CFTypeRef);
                 void (*cancel)(void *, void *, CFTypeRef); void (*perform)(void *); } MSRunLoopSourceContext;
extern CFTypeRef CFRunLoopSourceCreate(const void *alloc, long order, MSRunLoopSourceContext *ctx);
#define kCFStringEncodingUTF8 0x08000100
static CFTypeRef cfstr(const char *s) { return CFStringCreateWithCString(0, s, kCFStringEncodingUTF8); }

#define EXPORT __attribute__((visibility("default"), used))
typedef int32_t kern_return_t, OSStatus;
typedef uint32_t mach_port_t, io_object_t, CGDirectDisplayID;

/* ============================== IOKit ============================== */
#define kIOReturnUnsupported ((kern_return_t)0xe00002c7)
#define kIOReturnNotFound    ((kern_return_t)0xe00002f0)
EXPORT const mach_port_t kIOMasterPortDefault = 0;

/* A real (inert) CF object wherever the caller may CFRelease what it gets back. */
static CFTypeRef ms_cfdummy(const char *tag) { return cfstr(tag); }
static void ms_noop_perform(void *info) { (void)info; }
static CFTypeRef ms_inert_source(void) {      /* a run loop source that never fires: CFRunLoopAddSource needs a real one */
    static CFTypeRef s; if (!s) { MSRunLoopSourceContext c; memset(&c, 0, sizeof c); c.perform = ms_noop_perform; s = CFRunLoopSourceCreate(0, 0, &c); }
    return s;
}
static int g_notify_port_token;                /* IONotificationPortRef handed out: never dereferenced by callers */

EXPORT kern_return_t IOMasterPort(mach_port_t bootstrap, mach_port_t *port) { (void)bootstrap; if (port) *port = 0; return 0; }
EXPORT void *IOBSDNameMatching(mach_port_t p, uint32_t opts, const char *name) { (void)p; (void)opts; (void)name; return 0; }
EXPORT CFTypeRef IONotificationPortGetRunLoopSource(void *port) { (void)port; return ms_inert_source(); }
EXPORT kern_return_t IOServiceAddMatchingNotification(void *port, const char *type, void *matching, void *cb, void *ref, io_object_t *it) {
    (void)port; (void)type; (void)matching; (void)cb; (void)ref; if (it) *it = 0; return kIOReturnUnsupported; }
EXPORT kern_return_t IOCreatePlugInInterfaceForService(io_object_t s, const void *type, const void *iface, void ***plugin, int32_t *score) {
    (void)s; (void)type; (void)iface; if (plugin) *plugin = 0; if (score) *score = 0; return kIOReturnUnsupported; }
EXPORT io_object_t IORegistryEntryFromPath(mach_port_t p, const char *path) { (void)p; (void)path; return 0; }
EXPORT kern_return_t IORegistryEntryCreateCFProperties(io_object_t e, CFTypeRef *props, const void *alloc, uint32_t o) { (void)e; (void)alloc; (void)o; if (props) *props = 0; return kIOReturnUnsupported; }
EXPORT kern_return_t IORegistryEntryCreateIterator(io_object_t e, const char *plane, uint32_t o, io_object_t *it) { (void)e; (void)plane; (void)o; if (it) *it = 0; return kIOReturnUnsupported; }
EXPORT kern_return_t IORegistryEntryGetParentEntry(io_object_t e, const char *plane, io_object_t *parent) { (void)e; (void)plane; if (parent) *parent = 0; return kIOReturnNotFound; }
EXPORT kern_return_t IORegistryEntryGetName(io_object_t e, char *name) { (void)e; if (name) name[0] = 0; return kIOReturnUnsupported; }
/* power: no sleep notifications (an iPhone app is suspended instead), no battery info, assertions accepted */
EXPORT mach_port_t IORegisterForSystemPower(void *ref, void **port, void *cb, io_object_t *notifier) {
    (void)ref; (void)cb; if (port) *port = &g_notify_port_token; if (notifier) *notifier = 0; return 0; }
EXPORT kern_return_t IOAllowPowerChange(mach_port_t k, long id) { (void)k; (void)id; return 0; }
EXPORT kern_return_t IOCancelPowerChange(mach_port_t k, long id) { (void)k; (void)id; return 0; }
EXPORT CFTypeRef IOPSCopyPowerSourcesInfo(void) { return 0; }
EXPORT CFTypeRef IOPSCopyPowerSourcesList(CFTypeRef blob) { (void)blob; return 0; }
EXPORT int32_t IOPMAssertionCreateWithName(CFTypeRef type, uint32_t level, CFTypeRef name, uint32_t *id) { (void)type; (void)level; (void)name; if (id) *id = 1; return 0; }
EXPORT int32_t IOPMAssertionRelease(uint32_t id) { (void)id; return 0; }

/* HID: a manager that finds nothing. Controllers reach Unity and InControl through GameController instead. */
EXPORT CFTypeRef IOHIDManagerCreate(const void *alloc, uint32_t opts) { (void)alloc; (void)opts; return ms_cfdummy("MacShimHIDManager"); }
EXPORT int32_t IOHIDManagerOpen(CFTypeRef m, uint32_t o)  { (void)m; (void)o; return 0; }
EXPORT int32_t IOHIDManagerClose(CFTypeRef m, uint32_t o) { (void)m; (void)o; return 0; }
EXPORT CFTypeRef IOHIDManagerCopyDevices(CFTypeRef m) { (void)m; return CFSetCreate(0, 0, 0, 0); }
EXPORT void IOHIDManagerSetDeviceMatchingMultiple(CFTypeRef m, CFTypeRef a) { (void)m; (void)a; }
EXPORT void IOHIDManagerRegisterDeviceMatchingCallback(CFTypeRef m, void *cb, void *ctx) { (void)m; (void)cb; (void)ctx; }
EXPORT void IOHIDManagerRegisterDeviceRemovalCallback(CFTypeRef m, void *cb, void *ctx) { (void)m; (void)cb; (void)ctx; }
EXPORT void IOHIDManagerScheduleWithRunLoop(CFTypeRef m, CFTypeRef rl, CFTypeRef mode) { (void)m; (void)rl; (void)mode; }
EXPORT void IOHIDManagerUnscheduleFromRunLoop(CFTypeRef m, CFTypeRef rl, CFTypeRef mode) { (void)m; (void)rl; (void)mode; }
EXPORT CFTypeRef IOHIDDeviceCopyMatchingElements(CFTypeRef d, CFTypeRef match, uint32_t o) { (void)d; (void)match; (void)o; return CFArrayCreate(0, 0, 0, 0); }
EXPORT CFTypeRef IOHIDDeviceGetProperty(CFTypeRef d, CFTypeRef key) { (void)d; (void)key; return 0; }
EXPORT unsigned char IOHIDDeviceSetProperty(CFTypeRef d, CFTypeRef key, CFTypeRef v) { (void)d; (void)key; (void)v; return 0; }
EXPORT int32_t IOHIDDeviceSetReport(CFTypeRef d, int type, long id, const uint8_t *r, long len) { (void)d; (void)type; (void)id; (void)r; (void)len; return kIOReturnUnsupported; }
EXPORT int32_t IOHIDDeviceGetValue(CFTypeRef d, CFTypeRef el, CFTypeRef *v) { (void)d; (void)el; if (v) *v = 0; return kIOReturnUnsupported; }
EXPORT void IOHIDDeviceRegisterInputReportCallback(CFTypeRef d, uint8_t *r, long len, void *cb, void *ctx) { (void)d; (void)r; (void)len; (void)cb; (void)ctx; }
EXPORT void IOHIDDeviceRegisterRemovalCallback(CFTypeRef d, void *cb, void *ctx) { (void)d; (void)cb; (void)ctx; }
EXPORT void IOHIDDeviceScheduleWithRunLoop(CFTypeRef d, CFTypeRef rl, CFTypeRef mode) { (void)d; (void)rl; (void)mode; }
EXPORT void IOHIDDeviceUnscheduleFromRunLoop(CFTypeRef d, CFTypeRef rl, CFTypeRef mode) { (void)d; (void)rl; (void)mode; }
EXPORT unsigned long IOHIDElementGetTypeID(void) { return 0x7fff0001; }      /* matches no CF object */
EXPORT CFTypeRef IOHIDElementGetDevice(CFTypeRef e) { (void)e; return 0; }
EXPORT CFTypeRef IOHIDElementGetChildren(CFTypeRef e) { (void)e; return 0; }
EXPORT uint32_t IOHIDElementGetCookie(CFTypeRef e) { (void)e; return 0; }
EXPORT int IOHIDElementGetType(CFTypeRef e) { (void)e; return 0; }
EXPORT uint32_t IOHIDElementGetUsage(CFTypeRef e) { (void)e; return 0; }
EXPORT uint32_t IOHIDElementGetUsagePage(CFTypeRef e) { (void)e; return 0; }
EXPORT long IOHIDElementGetLogicalMin(CFTypeRef e) { (void)e; return 0; }
EXPORT long IOHIDElementGetLogicalMax(CFTypeRef e) { (void)e; return 0; }
EXPORT CFTypeRef IOHIDValueGetElement(CFTypeRef v) { (void)v; return 0; }
EXPORT long IOHIDValueGetIntegerValue(CFTypeRef v) { (void)v; return 0; }
EXPORT long IOHIDValueGetLength(CFTypeRef v) { (void)v; return 0; }
EXPORT CFTypeRef IOHIDQueueCreate(const void *alloc, CFTypeRef dev, long depth, uint32_t o) { (void)alloc; (void)dev; (void)depth; (void)o; return ms_cfdummy("MacShimHIDQueue"); }
EXPORT void IOHIDQueueAddElement(CFTypeRef q, CFTypeRef e) { (void)q; (void)e; }
EXPORT unsigned char IOHIDQueueContainsElement(CFTypeRef q, CFTypeRef e) { (void)q; (void)e; return 0; }
EXPORT CFTypeRef IOHIDQueueCopyNextValueWithTimeout(CFTypeRef q, double t) { (void)q; (void)t; return 0; }
EXPORT void IOHIDQueueStart(CFTypeRef q) { (void)q; }
EXPORT void IOHIDQueueStop(CFTypeRef q) { (void)q; }

/* ============================== Carbon: keyboard layouts ============================== */
EXPORT CFTypeRef kTISPropertyInputSourceID, kTISPropertyInputSourceType, kTISPropertyUnicodeKeyLayoutData,
                 kTISTypeKeyboardLayout, kTISNotifySelectedKeyboardInputSourceChanged;
__attribute__((constructor)) static void ms_init_tis(void) {
    kTISPropertyInputSourceID = cfstr("TISPropertyInputSourceID");
    kTISPropertyInputSourceType = cfstr("TISPropertyInputSourceType");
    kTISPropertyUnicodeKeyLayoutData = cfstr("TISPropertyUnicodeKeyLayoutData");
    kTISTypeKeyboardLayout = cfstr("TISTypeKeyboardLayout");
    kTISNotifySelectedKeyboardInputSourceChanged = cfstr("TISNotifySelectedKeyboardInputSourceChanged");
}
static CFTypeRef ms_input_source(void) { static CFTypeRef s; if (!s) s = cfstr("com.apple.keylayout.US"); return s; }
EXPORT CFTypeRef TISCopyCurrentKeyboardInputSource(void) { return CFRetain(ms_input_source()); }
EXPORT CFTypeRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) { return CFRetain(ms_input_source()); }
EXPORT CFTypeRef TISGetInputSourceProperty(CFTypeRef src, CFTypeRef key) {     /* "Get": not retained */
    (void)src;
    if (key == kTISPropertyInputSourceID) return ms_input_source();
    if (key == kTISPropertyInputSourceType) return kTISTypeKeyboardLayout;
    return 0;                                                                  /* no uchr data: nothing to translate */
}
EXPORT uint8_t LMGetKbdType(void) { return 40; }                              /* ANSI */
EXPORT double GetCurrentEventTime(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

/* ============================== CoreServices ============================== */
#define gestaltUndefSelectorErr (-5551)
EXPORT OSStatus Gestalt(uint32_t sel, int32_t *resp) {        /* same version sysctl kern.osproductversion reports */
    if (!resp) return -50;
    switch (sel) {
        case 0x73797331: *resp = 15; return 0;                 /* 'sys1' */
        case 0x73797332: *resp = 5; return 0;                  /* 'sys2' */
        case 0x73797333: *resp = 0; return 0;                  /* 'sys3' */
        case 0x73797376: *resp = 0x10F5; return 0;             /* 'sysv' (saturated BCD, as on macOS 11+) */
    }
    *resp = 0; return gestaltUndefSelectorErr;
}
EXPORT OSStatus UCKeyTranslate(const void *layout, uint16_t key, uint16_t action, uint32_t mods, uint32_t kbType, uint32_t opts,
                               uint32_t *dead, unsigned long maxLen, unsigned long *len, uint16_t *out) {
    (void)layout; (void)key; (void)action; (void)mods; (void)kbType; (void)opts; (void)maxLen; (void)out;
    if (dead) *dead = 0; if (len) *len = 0; return -50;
}
EXPORT OSStatus UpdateSystemActivity(uint8_t a) { (void)a; return 0; }
/* macOS's CoreServices re-exports libm; UnityPlayer binds these five through it, so forward them to libsystem_m */
static void *ms_libm(const char *name) {
    static void *h; if (!h) h = dlopen("/usr/lib/system/libsystem_m.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (!h) h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
    return h ? dlsym(h, name) : 0;
}
typedef struct { unsigned long long fpsr, fpcr; } ms_fenv_t;               /* arm64 fenv_t */
EXPORT const ms_fenv_t ms_FE_DFL_ENV __asm("__FE_DFL_ENV") = { 0, 0 };
EXPORT int ms_fegetenv(ms_fenv_t *e) __asm("_fegetenv");
EXPORT int ms_fegetenv(ms_fenv_t *e) { static int (*f)(ms_fenv_t *); if (!f) f = (int (*)(ms_fenv_t *))ms_libm("fegetenv"); return f ? f(e) : -1; }
EXPORT int ms_fesetenv(const ms_fenv_t *e) __asm("_fesetenv");
EXPORT int ms_fesetenv(const ms_fenv_t *e) {
    static int (*f)(const ms_fenv_t *); static const ms_fenv_t *dfl;
    if (!f) { f = (int (*)(const ms_fenv_t *))ms_libm("fesetenv"); dfl = (const ms_fenv_t *)ms_libm("_FE_DFL_ENV"); }
    if (e == &ms_FE_DFL_ENV && dfl) e = dfl;                                   /* libm may treat its own default specially */
    return f ? f(e) : -1;
}
EXPORT double ms_exp2(double x) __asm("_exp2");
EXPORT double ms_exp2(double x) { static double (*f)(double); if (!f) f = (double (*)(double))ms_libm("exp2"); return f(x); }
EXPORT float ms_modff(float x, float *ip) __asm("_modff");
EXPORT float ms_modff(float x, float *ip) { static float (*f)(float, float *); if (!f) f = (float (*)(float, float *))ms_libm("modff"); return f(x, ip); }

/* ============================== OpenGL: not available ============================== */
#define kCGLBadPixelFormat 10000
#define kCGLBadRendererInfo 10007
EXPORT int CGLChoosePixelFormat(const int *attrs, void **pix, int *n) { (void)attrs; if (pix) *pix = 0; if (n) *n = 0; return kCGLBadPixelFormat; }
EXPORT int CGLDestroyPixelFormat(void *pix) { (void)pix; return 0; }
EXPORT void *CGLGetPixelFormat(void *ctx) { (void)ctx; return 0; }
EXPORT int CGLCreateContext(void *pix, void *share, void **ctx) { (void)pix; (void)share; if (ctx) *ctx = 0; return kCGLBadPixelFormat; }
EXPORT int CGLDestroyContext(void *ctx) { (void)ctx; return 0; }
EXPORT void CGLReleaseContext(void *ctx) { (void)ctx; }
EXPORT void *CGLGetCurrentContext(void) { return 0; }
EXPORT int CGLSetCurrentContext(void *ctx) { (void)ctx; return 0; }
EXPORT int CGLSetParameter(void *ctx, int p, const int *v) { (void)ctx; (void)p; (void)v; return 0; }
EXPORT int CGLEnable(void *ctx, int p) { (void)ctx; (void)p; return 0; }
EXPORT int CGLFlushDrawable(void *ctx) { (void)ctx; return 0; }
EXPORT int CGLQueryRendererInfo(uint32_t mask, void **info, int *n) { (void)mask; if (info) *info = 0; if (n) *n = 0; return kCGLBadRendererInfo; }
EXPORT int CGLDescribeRenderer(void *info, int idx, int prop, int *v) { (void)info; (void)idx; (void)prop; if (v) *v = 0; return kCGLBadRendererInfo; }
EXPORT int CGLDestroyRendererInfo(void *info) { (void)info; return 0; }
EXPORT const char *CGLErrorString(int e) { (void)e; return "OpenGL is not available on iOS"; }
EXPORT void *glFenceSync(uint32_t cond, uint32_t flags) { (void)cond; (void)flags; return 0; }
EXPORT uint32_t glClientWaitSync(void *s, uint32_t flags, uint64_t t) { (void)s; (void)flags; (void)t; return 0x911A; }   /* GL_ALREADY_SIGNALED */
EXPORT void glDeleteSync(void *s) { (void)s; }
EXPORT void glFlush(void) {}

/* ============================== CoreGraphics: remaining display calls ============================== */
typedef struct { double w, h; } MSSize;
EXPORT int32_t CGDisplayHideCursor(CGDirectDisplayID d) { (void)d; return 0; }
EXPORT int32_t CGDisplayShowCursor(CGDirectDisplayID d) { (void)d; return 0; }
EXPORT uint32_t CGDisplayIDToOpenGLDisplayMask(CGDirectDisplayID d) { (void)d; return 1; }
EXPORT CFTypeRef CGDisplayModeCopyPixelEncoding(void *mode) { (void)mode; return cfstr("--------RRRRRRRRGGGGGGGGBBBBBBBB"); }   /* IO32BitDirectPixels */
EXPORT int32_t CGDisplayRegisterReconfigurationCallback(void *cb, void *info) { (void)cb; (void)info; return 0; }
EXPORT MSSize CGDisplayScreenSize(CGDirectDisplayID d) {      /* millimetres, at the ~460 ppi of current iPhones */
    double w, h, s; (void)d; MacShimScreenInfo(&w, &h, &s, 0); MSSize r = { w * s / 460.0 * 25.4, h * s / 460.0 * 25.4 }; return r;
}
EXPORT uint64_t CGEventSourceFlagsState(int32_t state) { (void)state; return 0; }
EXPORT void CGGetLastMouseDelta(int32_t *dx, int32_t *dy) { if (dx) *dx = 0; if (dy) *dy = 0; }

/* ============================== audio ==============================
 * FMOD (Tunic's audio, and Unity's own) opens the Mac "HAL output" unit for the default CoreAudio device and asks that
 * device for its rate, buffer size and stream format. iOS has no HAL devices: the shim answers for one stereo float
 * output device (id 1, stream id 2) at the AVAudioSession's rate, and AudioComponentFindNext hands back RemoteIO when
 * the HAL / default output unit is asked for. Property calls that only exist on the HAL unit are accepted and dropped.
 * Every query is logged once, so missing answers show up in macshim.log. */
#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))
#define kAudioHardwareUnknownPropertyError ((OSStatus)0x77686F3F)   /* 'who?' */
#define kAudioHardwareBadObjectError ((OSStatus)0x216F626A)          /* '!obj' */
typedef struct { uint32_t selector, scope, element; } MSAddr;
typedef struct { double rate; uint32_t fmt, flags, bytesPerPacket, framesPerPacket, bytesPerFrame, channels, bits, reserved; } MSASBD;
typedef struct { double lo, hi; } MSRange;
enum { MS_DEV = 1, MS_STREAM = 2 };
static uint32_t g_bufFrames = 512;

static void ms_log4(const char *what, uint32_t obj, const MSAddr *a, int answered) {
    static uint32_t seen[96]; static int n;
    uint32_t key = a ? a->selector ^ (a->scope * 31) ^ obj : obj;
    for (int i = 0; i < n; i++) if (seen[i] == key) return;
    if (n < 96) seen[n++] = key; else return;
    char b[64]; uint32_t s = a ? a->selector : 0, sc = a ? a->scope : 0;
    snprintf(b, sizeof b, "obj %u '%c%c%c%c' scope '%c%c%c%c' %s", obj, s >> 24, s >> 16 & 255, s >> 8 & 255, s & 255,
             sc >> 24, sc >> 16 & 255, sc >> 8 & 255, sc & 255, answered ? "answered" : "UNANSWERED");
    MacShimLogC(what, b);
}
static MSASBD ms_format(void) {
    MSASBD f = { MacShimAudioSampleRate(), FOURCC('l','p','c','m'), 9 /* float | packed */, 8, 1, 8, 2, 32, 0 }; return f;
}
/* writes the answer to buf (if not NULL) and returns its size, or 0 for "unknown property" */
static uint32_t ms_audio_answer(uint32_t obj, const MSAddr *a, void *buf, uint32_t cap) {
    uint8_t tmp[64]; uint32_t n = 0; uint32_t u; double f;
    memset(tmp, 0, sizeof tmp);
    #define PUT(v) do { memcpy(tmp, &(v), sizeof(v)); n = sizeof(v); } while (0)
    uint32_t s = a->selector, sc = a->scope;
    int input = sc == FOURCC('i','n','p','t');
    switch (s) {
        case FOURCC('d','O','u','t'): case FOURCC('s','O','u','t'): u = MS_DEV; PUT(u); break;      /* default (system) output */
        case FOURCC('d','I','n',' '): u = 0; PUT(u); break;                                       /* no default input */
        case FOURCC('d','e','v','#'): u = MS_DEV; PUT(u); break;                                  /* device list */
        case FOURCC('n','s','r','t'): f = MacShimAudioSampleRate(); PUT(f); break;                /* nominal sample rate */
        case FOURCC('n','s','r','#'): { MSRange r = { MacShimAudioSampleRate(), MacShimAudioSampleRate() }; PUT(r); break; }
        case FOURCC('f','s','i','z'): u = g_bufFrames; PUT(u); break;                             /* buffer frame size */
        case FOURCC('f','s','z','#'): { MSRange r = { 64, 4096 }; PUT(r); break; }
        case FOURCC('s','t','m','#'): if (input) n = 0; else { u = MS_STREAM; PUT(u); } break;     /* streams */
        case FOURCC('s','l','a','y'): {                                                           /* stream configuration */
            uint32_t list[4] = { 1, 2, 0, 0 };          /* AudioBufferList: 1 buffer, 2 channels, size 0, data NULL */
            if (input) { uint32_t none = 0; PUT(none); } else { memcpy(tmp, list, 4 + 16); n = 4 + 16; }
            break;
        }
        case FOURCC('d','c','h','2'): { uint32_t ch[2] = { 1, 2 }; PUT(ch); break; }               /* stereo channels */
        case FOURCC('s','r','n','d'): { uint32_t lay[3] = { (101u << 16) | 2, 0, 0 }; PUT(lay); break; }   /* stereo layout */
        case FOURCC('s','f','m','t'): case FOURCC('p','f','t',' '): { MSASBD fm = ms_format(); PUT(fm); break; }
        case FOURCC('l','i','v','n'): case FOURCC('g','o','i','n'): u = 1; PUT(u); break;           /* alive, running */
        case FOURCC('l','t','n','c'): case FOURCC('s','a','f','t'): u = 0; PUT(u); break;          /* latency, safety offset */
        case FOURCC('t','r','a','n'): u = FOURCC('b','l','t','n'); PUT(u); break;                  /* built-in */
        case FOURCC('s','d','i','r'): u = input ? 1 : 0; PUT(u); break;                            /* stream direction */
        case FOURCC('s','t','r','m'): u = MS_DEV; PUT(u); break;
        case FOURCC('h','o','g','p'): u = (uint32_t)-1; PUT(u); break;                             /* nobody hogs it */
        case FOURCC('l','n','a','m'): case FOURCC('l','m','a','k'): case FOURCC('u','i','d',' '): case FOURCC('m','u','i','d'): {
            CFTypeRef str = cfstr(s == FOURCC('l','m','a','k') ? "Apple" : s == FOURCC('l','n','a','m') ? "iPhone Speaker" : "MacShimOutput");
            if (buf && cap >= sizeof str) memcpy(buf, &str, sizeof str);      /* caller releases */
            return sizeof str;
        }
        default: return 0;
    }
    #undef PUT
    if (n == 0 && s != FOURCC('s','t','m','#')) return 0;
    if (buf) memcpy(buf, tmp, n < cap ? n : cap);
    return n ? n : 0xFFFFFFFF;          /* 0xFFFFFFFF = "answered, empty" */
}
EXPORT OSStatus AudioObjectGetPropertyDataSize(uint32_t o, const MSAddr *a, uint32_t qs, const void *q, uint32_t *sz) {
    (void)qs; (void)q; uint32_t n = a ? ms_audio_answer(o, a, 0, 0) : 0; ms_log4("audio size", o, a, n != 0);
    if (!n) { if (sz) *sz = 0; return kAudioHardwareUnknownPropertyError; }
    if (sz) *sz = n == 0xFFFFFFFF ? 0 : n; return 0;
}
EXPORT OSStatus AudioObjectGetPropertyData(uint32_t o, const MSAddr *a, uint32_t qs, const void *q, uint32_t *sz, void *d) {
    (void)qs; (void)q; uint32_t n = a ? ms_audio_answer(o, a, d, sz ? *sz : 0) : 0; ms_log4("audio get", o, a, n != 0);
    if (!n) return kAudioHardwareUnknownPropertyError;
    if (sz) *sz = n == 0xFFFFFFFF ? 0 : (n < *sz ? n : *sz); return 0;
}
EXPORT OSStatus AudioObjectSetPropertyData(uint32_t o, const MSAddr *a, uint32_t qs, const void *q, uint32_t sz, const void *d) {
    (void)qs; (void)q; ms_log4("audio set", o, a, 1);
    if (a && a->selector == FOURCC('f','s','i','z') && d && sz >= 4) { memcpy(&g_bufFrames, d, 4); MacShimAudioSetBufferFrames(g_bufFrames); }
    return 0;                                                  /* everything else: accepted, nothing to change on iOS */
}
EXPORT unsigned char AudioObjectHasProperty(uint32_t o, const MSAddr *a) { return a && ms_audio_answer(o, a, 0, 0) != 0; }
EXPORT OSStatus AudioObjectIsPropertySettable(uint32_t o, const MSAddr *a, unsigned char *out) { (void)o; (void)a; if (out) *out = 1; return 0; }
EXPORT OSStatus AudioObjectAddPropertyListener(uint32_t o, const MSAddr *a, void *cb, void *ctx) { (void)o; (void)a; (void)cb; (void)ctx; return 0; }
EXPORT OSStatus AudioObjectRemovePropertyListener(uint32_t o, const MSAddr *a, void *cb, void *ctx) { (void)o; (void)a; (void)cb; (void)ctx; return 0; }
EXPORT OSStatus AudioObjectAddPropertyListenerBlock(uint32_t o, const MSAddr *a, void *q, void *blk) { (void)o; (void)a; (void)q; (void)blk; return 0; }
EXPORT OSStatus AudioObjectRemovePropertyListenerBlock(uint32_t o, const MSAddr *a, void *q, void *blk) { (void)o; (void)a; (void)q; (void)blk; return 0; }
/* the pre-10.6 HAL calls Unity still imports: (device, channel, isInput, property) -> same answers */
static MSAddr ms_legacy(uint32_t prop, int input) { MSAddr a = { prop, input ? FOURCC('i','n','p','t') : FOURCC('o','u','t','p'), 0 }; return a; }
EXPORT OSStatus AudioHardwareGetPropertyInfo(uint32_t prop, uint32_t *sz, unsigned char *w) { MSAddr a = ms_legacy(prop, 0); if (w) *w = 0; return AudioObjectGetPropertyDataSize(1, &a, 0, 0, sz); }
EXPORT OSStatus AudioHardwareGetProperty(uint32_t prop, uint32_t *sz, void *d) { MSAddr a = ms_legacy(prop, 0); return AudioObjectGetPropertyData(1, &a, 0, 0, sz, d); }
EXPORT OSStatus AudioHardwareAddPropertyListener(uint32_t prop, void *cb, void *ctx) { (void)prop; (void)cb; (void)ctx; return 0; }
EXPORT OSStatus AudioDeviceGetPropertyInfo(uint32_t dev, uint32_t ch, unsigned char in, uint32_t prop, uint32_t *sz, unsigned char *w) { (void)ch; MSAddr a = ms_legacy(prop, in); if (w) *w = 0; return AudioObjectGetPropertyDataSize(dev, &a, 0, 0, sz); }
EXPORT OSStatus AudioDeviceGetProperty(uint32_t dev, uint32_t ch, unsigned char in, uint32_t prop, uint32_t *sz, void *d) { (void)ch; MSAddr a = ms_legacy(prop, in); return AudioObjectGetPropertyData(dev, &a, 0, 0, sz, d); }
EXPORT OSStatus AudioDeviceSetProperty(uint32_t dev, const void *when, uint32_t ch, unsigned char in, uint32_t prop, uint32_t sz, const void *d) { (void)when; (void)ch; MSAddr a = ms_legacy(prop, in); return AudioObjectSetPropertyData(dev, &a, 0, 0, sz, d); }

/* AudioUnit -> AudioToolbox. Mac output units become RemoteIO; HAL-only properties are dropped. */
typedef struct { uint32_t type, subType, manufacturer, flags, flagsMask; } MSACDesc;
static void *ms_at(const char *name) {
    static void *h; if (!h) h = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
    return h ? dlsym(h, name) : 0;
}
#define AT(ret, name, args) static ret (*real) args; if (!real) real = (ret (*) args)ms_at(name); if (!real) return -1
#define kAudioOutputUnitProperty_CurrentDevice 2000
EXPORT void *AudioComponentFindNext(void *after, const MSACDesc *desc) {
    static void *(*real)(void *, const MSACDesc *); if (!real) real = (void *(*)(void *, const MSACDesc *))ms_at("AudioComponentFindNext");
    if (!real) return 0;
    if (desc && desc->type == FOURCC('a','u','o','u') &&
        (desc->subType == FOURCC('a','h','a','l') || desc->subType == FOURCC('d','e','f',' ') || desc->subType == FOURCC('s','y','s',' '))) {
        MSACDesc d = *desc; d.subType = FOURCC('r','i','o','c'); d.manufacturer = FOURCC('a','p','p','l');
        MacShimAudioSampleRate();                              /* the session must be active before RemoteIO starts */
        static int said; if (!said++) MacShimLogC("audio", "Mac output unit requested -> RemoteIO");
        return real(after, &d);
    }
    return real(after, desc);
}
EXPORT OSStatus AudioComponentInstanceNew(void *comp, void **out) { AT(OSStatus, "AudioComponentInstanceNew", (void *, void **)); return real(comp, out); }
EXPORT OSStatus AudioComponentInstanceDispose(void *u) { AT(OSStatus, "AudioComponentInstanceDispose", (void *)); return real(u); }
EXPORT OSStatus AudioUnitInitialize(void *u) { AT(OSStatus, "AudioUnitInitialize", (void *)); OSStatus r = real(u); if (r) { char b[32]; snprintf(b, sizeof b, "%d", (int)r); MacShimLogC("audio: AudioUnitInitialize failed", b); } return r; }
EXPORT OSStatus AudioUnitUninitialize(void *u) { AT(OSStatus, "AudioUnitUninitialize", (void *)); return real(u); }
EXPORT OSStatus AudioOutputUnitStart(void *u) { AT(OSStatus, "AudioOutputUnitStart", (void *)); OSStatus r = real(u); { char b[32]; snprintf(b, sizeof b, "%d", (int)r); MacShimLogC("audio: output unit started", b); } return r; }
EXPORT OSStatus AudioOutputUnitStop(void *u) { AT(OSStatus, "AudioOutputUnitStop", (void *)); return real(u); }
EXPORT OSStatus AudioUnitRender(void *u, uint32_t *flags, const void *ts, uint32_t bus, uint32_t frames, void *data) {
    AT(OSStatus, "AudioUnitRender", (void *, uint32_t *, const void *, uint32_t, uint32_t, void *)); return real(u, flags, ts, bus, frames, data); }
EXPORT OSStatus AudioUnitSetProperty(void *u, uint32_t id, uint32_t scope, uint32_t el, const void *d, uint32_t sz) {
    AT(OSStatus, "AudioUnitSetProperty", (void *, uint32_t, uint32_t, uint32_t, const void *, uint32_t));
    if (id == kAudioOutputUnitProperty_CurrentDevice) return 0;           /* HAL only: RemoteIO is always the speaker/route */
    OSStatus r = real(u, id, scope, el, d, sz);
    if (r) { char b[48]; snprintf(b, sizeof b, "property %u scope %u el %u -> %d", id, scope, el, (int)r); MacShimLogC("audio: AudioUnitSetProperty failed", b); }
    return r;
}
EXPORT OSStatus AudioUnitGetProperty(void *u, uint32_t id, uint32_t scope, uint32_t el, void *d, uint32_t *sz) {
    AT(OSStatus, "AudioUnitGetProperty", (void *, uint32_t, uint32_t, uint32_t, void *, uint32_t *));
    if (id == kAudioOutputUnitProperty_CurrentDevice && d && sz && *sz >= 4) { uint32_t dev = MS_DEV; memcpy(d, &dev, 4); *sz = 4; return 0; }
    return real(u, id, scope, el, d, sz);
}

/* ============================== Security: keychain calls (macOS only) ============================== */
#define errSecUnimplemented ((int32_t)-4)
#define errSecItemNotFound ((int32_t)-25300)
EXPORT int32_t SecKeychainOpen(const char *path, void **kc) { (void)path; if (kc) *kc = 0; return errSecUnimplemented; }
EXPORT int32_t SecKeychainSearchCreateFromAttributes(const void *kc, uint32_t cls, const void *attrs, void **search) { (void)kc; (void)cls; (void)attrs; if (search) *search = 0; return errSecUnimplemented; }
EXPORT int32_t SecKeychainSearchCopyNext(void *search, void **item) { (void)search; if (item) *item = 0; return errSecItemNotFound; }
EXPORT int32_t SecKeychainItemCopyContent(void *item, void *cls, void *attrs, uint32_t *len, void **data) { (void)item; (void)cls; (void)attrs; if (len) *len = 0; if (data) *data = 0; return errSecUnimplemented; }
EXPORT int32_t SecKeychainItemFreeContent(void *attrs, void *data) { (void)attrs; (void)data; return 0; }
EXPORT int32_t SecCertificateGetData(const void *cert, void *data) { (void)cert; (void)data; return errSecUnimplemented; }
EXPORT int32_t SecTrustCopyAnchorCertificates(CFTypeRef *anchors) { if (anchors) *anchors = CFArrayCreate(0, 0, 0, 0); return 0; }

/* ============================== libSystem: syslog$DARWIN_EXTSN ============================== */
EXPORT void ms_syslog(int pri, const char *fmt, ...) __asm("_syslog$DARWIN_EXTSN");
EXPORT void ms_syslog(int pri, const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsyslog(pri, fmt, ap); va_end(ap); }
