/*
 * UnityShim.m - what Tunic's Unity 2020.3 Mac player needs on top of CyPort's AppKit layer (MacShim.m):
 *
 *   - the Mac-style app folder Unity finds its data and plugins through (MacShimMacAppRoot)
 *   - library path mapping for the dlopen hook (macOS framework paths, bare plugin names)
 *   - AppKit classes / constants MacShim.m doesn't have (NSColor, NSPasteboard, NSViewController, ...)
 *   - CVDisplayLink on top of CADisplayLink (Unity paces its frames with it)
 *   - AVAudioSession setup for the RemoteIO output (UnityShimC.c "audio")
 *   - NSBundle answers for UnityPlayer / GameAssembly: the main bundle is the Mac-style folder
 *
 * Unknown AppKit selectors still land in MSBase (MacShim.m): logged once and answered with 0/nil.
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <CoreVideo/CVBase.h>
#import <CoreVideo/CVReturn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

extern void MacShimLogC(const char *what, const char *detail);
extern void MacShimScreenInfo(double *w, double *h, double *s, double *fps);
extern NSString *MacShimDataFolder(void);
static void UMLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void UMLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    MacShimLogC("unity", s.UTF8String);
}

/* plugins shipped in the app's Frameworks folder (retargeted from Tunic.app/Contents/PlugIns/X.bundle) */
static NSArray<NSString *> *UMPlugins(void) { return @[ @"fmodstudio", @"InControlNative", @"resonanceaudio" ]; }
static NSString *UMFrameworks(void) { return NSBundle.mainBundle.privateFrameworksPath; }

/* ---------------------------------------------------------------- the Mac-style app folder
 * Unity derives everything from its executable's path: <app>/Contents/Resources/Data, <app>/Contents/PlugIns. On iOS
 * the app bundle is flat and read-only, so the shim builds this folder in Library/Application Support/MacShim:
 *   Tunic.app/Contents/MacOS/Secret Legend   empty file (realpath() on the executable path must succeed)
 *   Tunic.app/Contents/Resources             -> the game folder (in the app's Game/Resources, or Documents/Tunic)
 *   Tunic.app/Contents/Info.plist            -> the Mac Info.plist shipped in Game/
 *   Tunic.app/Contents/PlugIns/X.bundle      Info.plist + Contents/MacOS/X -> Frameworks/X.dylib (signed with the app)
 * Rebuilt at every launch: the app's own path changes with each install. */
NSString *MacShimMacAppRoot(void) {
    static NSString *root; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *r = [support stringByAppendingPathComponent:@"MacShim/Tunic.app"], *c = [r stringByAppendingPathComponent:@"Contents"];
        [fm removeItemAtPath:r error:nil];                       /* only links and generated files live here */
        for (NSString *d in @[ @"MacOS", @"PlugIns" ]) [fm createDirectoryAtPath:[c stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
        [NSData.data writeToFile:[c stringByAppendingPathComponent:@"MacOS/Secret Legend"] atomically:NO];
        NSString *data = MacShimDataFolder(); NSError *e = nil;
        if (data && ![fm createSymbolicLinkAtPath:[c stringByAppendingPathComponent:@"Resources"] withDestinationPath:data error:&e])
            UMLog(@"game folder link failed: %@", e.localizedDescription);
        /* Contents/Frameworks -> the app's Frameworks (GameAssembly.dylib, where a Mac build keeps it) */
        [fm createSymbolicLinkAtPath:[c stringByAppendingPathComponent:@"Frameworks"] withDestinationPath:UMFrameworks() error:nil];
        NSString *macPlist = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Game/Info.plist"];
        if ([fm fileExistsAtPath:macPlist]) [fm createSymbolicLinkAtPath:[c stringByAppendingPathComponent:@"Info.plist"] withDestinationPath:macPlist error:nil];
        for (NSString *p in UMPlugins()) {
            NSString *lib = [UMFrameworks() stringByAppendingPathComponent:[p stringByAppendingPathExtension:@"dylib"]];
            if (![fm fileExistsAtPath:lib]) continue;
            NSString *b = [c stringByAppendingPathComponent:[NSString stringWithFormat:@"PlugIns/%@.bundle/Contents", p]];
            [fm createDirectoryAtPath:[b stringByAppendingPathComponent:@"MacOS"] withIntermediateDirectories:YES attributes:nil error:nil];
            [@{ @"CFBundleExecutable": p, @"CFBundleIdentifier": [@"com.macshim.plugin." stringByAppendingString:p], @"CFBundleName": p,
                @"CFBundlePackageType": @"BNDL", @"CFBundleInfoDictionaryVersion": @"6.0" } writeToFile:[b stringByAppendingPathComponent:@"Info.plist"] atomically:NO];
            [fm createSymbolicLinkAtPath:[b stringByAppendingPathComponent:[@"MacOS" stringByAppendingPathComponent:p]] withDestinationPath:lib error:nil];
        }
        root = r;
        UMLog(@"Mac app folder ready: %@ (data %@)", r, data ?: @"none");
    });
    return root;
}

/* ---------------------------------------------------------------- dlopen path mapping (MacShim.m's dlopen hook)
 * NULL = open the path as given. */
static BOOL UMMacOnly(NSString *fw) {
    static NSSet *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [NSSet setWithArray:@[ @"AppKit", @"Cocoa", @"Carbon", @"IOKit", @"OpenGL", @"Quartz", @"CoreServices",
                                                    @"SecurityFoundation", @"ForceFeedback", @"AudioUnit", @"CoreAudio" ]]; });
    return [s containsObject:fw];
}
const char *MacShimMapLibraryPath(const char *path, char *buf, size_t len) {
    NSString *p = @(path), *out = nil;
    if ([p hasPrefix:@"/System/Library/Frameworks/"]) {          /* .../X.framework/Versions/A/X -> .../X.framework/X, or the shim */
        NSArray *parts = p.pathComponents;                       /* "/", System, Library, Frameworks, X.framework, ... */
        if (parts.count > 5 && [parts[4] hasSuffix:@".framework"]) {
            NSString *fw = [parts[4] stringByDeletingPathExtension];
            if (UMMacOnly(fw)) out = [UMFrameworks() stringByAppendingPathComponent:@"libMacShim.dylib"];
            else if ([p containsString:@"/Versions/"]) out = [NSString stringWithFormat:@"/System/Library/Frameworks/%@.framework/%@", fw, fw];
        }
    } else if (![p hasPrefix:@"/"] || ![NSFileManager.defaultManager fileExistsAtPath:p]) {
        /* plugin by name ("fmodstudio", "libfmodstudio.dylib", "fmodstudio.bundle", .../fmodstudio.bundle/Contents/MacOS/fmodstudio) */
        for (NSString *name in UMPlugins()) {
            NSString *leaf = p.lastPathComponent;
            if ([leaf isEqualToString:name] || [leaf isEqualToString:[name stringByAppendingPathExtension:@"dylib"]] ||
                [leaf isEqualToString:[@"lib" stringByAppendingString:[name stringByAppendingPathExtension:@"dylib"]]] ||
                [leaf isEqualToString:[name stringByAppendingPathExtension:@"bundle"]]) {
                NSString *lib = [UMFrameworks() stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"dylib"]];
                if ([NSFileManager.defaultManager fileExistsAtPath:lib]) out = lib;
                break;
            }
        }
    }
    if (!out || strlcpy(buf, out.fileSystemRepresentation, len) >= len) return NULL;
    return buf;
}

/* ---------------------------------------------------------------- AppKit constants and small classes */
NSString *const NSCalibratedRGBColorSpace = @"NSCalibratedRGBColorSpace";
NSString *const NSDeviceRGBColorSpace = @"NSDeviceRGBColorSpace";
NSString *const NSPasteboardTypeString = @"public.utf8-plain-text";
NSString *const NSTextInputContextKeyboardSelectionDidChangeNotification = @"NSTextInputContextKeyboardSelectionDidChangeNotification";
NSString *const NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";   /* same name MacShim.m posts */
const double NSAppKitVersionNumber = 2022.0;                     /* macOS 11 (InControlNative checks it) */
/* AVFoundation on iOS lacks these two capture presets; the shim re-exports AVFoundation and adds them */
NSString *const UMPreset320 __asm("_AVCaptureSessionPreset320x240") = @"AVCaptureSessionPreset320x240";
NSString *const UMPreset960 __asm("_AVCaptureSessionPreset960x540") = @"AVCaptureSessionPreset960x540";

@interface MSBase : NSObject @end                               /* MacShim.m: unknown selectors -> log + 0 */
@class NSView;

@interface NSColor : MSBase @property(nonatomic, strong) UIColor *ui; @end
@implementation NSColor
+ (instancetype)with:(UIColor *)c { NSColor *n = [self new]; n.ui = c; return n; }
+ (NSColor *)blackColor { return [self with:UIColor.blackColor]; }
+ (NSColor *)whiteColor { return [self with:UIColor.whiteColor]; }
+ (NSColor *)clearColor { return [self with:UIColor.clearColor]; }
+ (NSColor *)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self with:[UIColor colorWithRed:r green:g blue:b alpha:a]]; }
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self colorWithSRGBRed:r green:g blue:b alpha:a]; }
+ (NSColor *)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [self colorWithSRGBRed:r green:g blue:b alpha:a]; }
+ (NSColor *)colorWithCalibratedWhite:(CGFloat)w alpha:(CGFloat)a { return [self with:[UIColor colorWithWhite:w alpha:a]]; }
- (CGColorRef)CGColor { return self.ui.CGColor; }
- (NSColor *)colorUsingColorSpaceName:(NSString *)n { return self; }
- (void)set {} - (void)setFill {} - (void)setStroke {}
@end

@interface NSPasteboard : MSBase @end
@implementation NSPasteboard
+ (NSPasteboard *)generalPasteboard { static NSPasteboard *p; static dispatch_once_t o; dispatch_once(&o, ^{ p = [NSPasteboard new]; }); return p; }
- (NSInteger)clearContents { UIPasteboard.generalPasteboard.items = @[]; return 1; }
- (NSInteger)declareTypes:(NSArray *)t owner:(id)o { return 1; }
- (BOOL)setString:(NSString *)s forType:(NSString *)t { UIPasteboard.generalPasteboard.string = s ?: @""; return YES; }
- (NSString *)stringForType:(NSString *)t { return UIPasteboard.generalPasteboard.string; }
- (NSArray *)types { return UIPasteboard.generalPasteboard.hasStrings ? @[ NSPasteboardTypeString ] : @[]; }
- (NSString *)availableTypeFromArray:(NSArray *)a { return [a containsObject:NSPasteboardTypeString] && UIPasteboard.generalPasteboard.hasStrings ? NSPasteboardTypeString : nil; }
@end

@interface NSBitmapImageRep : MSBase @end
@implementation NSBitmapImageRep { NSInteger _w, _h, _row; unsigned char *_data; }
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)p pixelsWide:(NSInteger)w pixelsHigh:(NSInteger)h bitsPerSample:(NSInteger)b
                         samplesPerPixel:(NSInteger)s hasAlpha:(BOOL)a isPlanar:(BOOL)pl colorSpaceName:(NSString *)c
                             bytesPerRow:(NSInteger)r bitsPerPixel:(NSInteger)bp {
    self = [super init]; _w = w; _h = h; _row = r ?: w * 4; _data = calloc((size_t)(_row * h), 1); return self; }
- (unsigned char *)bitmapData { return _data; }
- (NSInteger)pixelsWide { return _w; } - (NSInteger)pixelsHigh { return _h; } - (NSInteger)bytesPerRow { return _row; }
- (void)dealloc { free(_data); }
@end

@interface NSInputManager : MSBase @end
@implementation NSInputManager + (NSInputManager *)currentInputManager { return nil; } @end

@interface NSOpenGLContext : MSBase @end                         /* Unity renders with Metal; never asked for a context */
@implementation NSOpenGLContext + (NSOpenGLContext *)currentContext { return nil; } + (void)clearCurrentContext {} @end

/* Unity subclasses NSViewController; it only needs a view to hold and the usual lifecycle hooks */
@interface NSViewController : MSBase @property(nonatomic, strong) NSView *view; @property(nonatomic, strong) id representedObject; @end
@implementation NSViewController { BOOL _loaded; }
- (instancetype)initWithNibName:(NSString *)n bundle:(NSBundle *)b { return [super init]; }
- (NSView *)view { if (!_view && !_loaded) { _loaded = YES; [self loadView]; if (_view) [self viewDidLoad]; } return _view; }
- (void)loadView {} - (void)viewDidLoad {} - (void)viewWillAppear {} - (void)viewDidAppear {} - (void)viewWillDisappear {} - (void)viewDidDisappear {}
- (BOOL)isViewLoaded { return _view != nil; }
@end

/* NSWindow screen <-> window conversions MacShim.m's NSWindow lacks (struct returns can't go through MSBase) */
static CGRect UMFrame(id w) { return ((CGRect (*)(id, SEL))objc_msgSend)(w, @selector(frame)); }
static CGRect UMToScreen(id self, SEL _cmd, CGRect r) { CGRect f = UMFrame(self); r.origin.x += f.origin.x; r.origin.y += f.origin.y; return r; }
static CGRect UMFromScreen(id self, SEL _cmd, CGRect r) { CGRect f = UMFrame(self); r.origin.x -= f.origin.x; r.origin.y -= f.origin.y; return r; }
static CGPoint UMPointToScreen(id self, SEL _cmd, CGPoint p) { CGRect f = UMFrame(self); return CGPointMake(p.x + f.origin.x, p.y + f.origin.y); }
static CGPoint UMPointFromScreen(id self, SEL _cmd, CGPoint p) { CGRect f = UMFrame(self); return CGPointMake(p.x - f.origin.x, p.y - f.origin.y); }
static CGPoint UMMouseInWindow(id self, SEL _cmd) {
    CGPoint m = ((CGPoint (*)(id, SEL))objc_msgSend)(NSClassFromString(@"NSEvent"), @selector(mouseLocation)); return UMPointFromScreen(self, _cmd, m); }
/* Window size / visibility calls Unity makes while sizing its Metal view (5th device run: logged as unimplemented, the
   struct ones came back as garbage through MSBase and Unity never drew a frame). Borderless full-screen windows:
   frame == content rect. Backing scale = the screen's. */
static CGFloat UMScale(void) { return ((CGFloat (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"NSScreen"), @selector(mainScreen)), @selector(backingScaleFactor)); }
static CGRect UMSameRectStyle(id self, SEL _cmd, CGRect r, NSUInteger style) { return r; }
static CGRect UMSameRect(id self, SEL _cmd, CGRect r) { return r; }
static CGRect UMToBacking(id self, SEL _cmd, CGRect r) { CGFloat s = UMScale(); return CGRectMake(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s); }
static CGRect UMFromBacking(id self, SEL _cmd, CGRect r) { CGFloat s = UMScale(); return CGRectMake(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s); }
static CGRect UMBackingAligned(id self, SEL _cmd, CGRect r, unsigned long long opts) { return CGRectIntegral(r); }
static NSUInteger UMOcclusionVisible(id self, SEL _cmd) { return 1 << 1; }          /* NSWindowOcclusionStateVisible */
static BOOL UMYes(id self, SEL _cmd) { return YES; }
static BOOL UMMouseInRect(id self, SEL _cmd, CGPoint p, CGRect r) { return CGRectContainsPoint(r, p); }

/* ---------------------------------------------------------------- CVDisplayLink
 * macOS calls the output callback on its own high-priority thread once per refresh. Here a CADisplayLink on a thread
 * of its own does the same, so Unity's pacing works as on a Mac (and never waits on the main thread).
 * The iOS SDK marks the CVDisplayLink / CVOpenGL* API unavailable, so these are defined under other C names with the
 * real symbol names (asm labels) and plain pointer types. */
typedef void *UMLinkRef;
typedef CVReturn (*UMLinkCallback)(UMLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags in, CVOptionFlags *outFlags, void *ctx);
@interface UMDisplayLink : NSObject {
@public UMLinkCallback cb; void *ctx; _Atomic BOOL running; CADisplayLink *link; NSThread *thread; double period;
}
@end
@implementation UMDisplayLink
- (void)tick:(CADisplayLink *)l {
    if (!running || !cb) return;
    double p = l.targetTimestamp - l.timestamp; if (p > 0) period = p;
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    CVTimeStamp now = { 0 }, out = { 0 };
    now.version = out.version = 0; now.videoTimeScale = out.videoTimeScale = 1000000000;
    now.hostTime = (uint64_t)(l.timestamp * 1e9 * tb.denom / tb.numer); out.hostTime = (uint64_t)(l.targetTimestamp * 1e9 * tb.denom / tb.numer);
    now.videoTime = (int64_t)(l.timestamp * 1e9); out.videoTime = (int64_t)(l.targetTimestamp * 1e9);
    now.videoRefreshPeriod = out.videoRefreshPeriod = (int64_t)(period * 1e9); now.rateScalar = out.rateScalar = 1;
    now.flags = out.flags = kCVTimeStampVideoTimeValid | kCVTimeStampHostTimeValid | kCVTimeStampVideoRefreshPeriodValid | kCVTimeStampRateScalarValid;
    CVOptionFlags flagsOut = 0;
    cb((__bridge void *)self, &now, &out, 0, &flagsOut, ctx);
}
- (void)threadMain {
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        double f = 60; MacShimScreenInfo(0, 0, 0, &f);
        if (@available(iOS 15.0, *)) link.preferredFrameRateRange = CAFrameRateRangeMake(30, (float)f, (float)f);
        else link.preferredFramesPerSecond = (NSInteger)f;
        [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        while (![NSThread currentThread].isCancelled) @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]]; }
        [link invalidate]; link = nil;
    }
}
@end
#define UM_EXPORT __attribute__((visibility("default"), used))
static UMDisplayLink *UMDL(UMLinkRef l) { return (__bridge UMDisplayLink *)l; }
UM_EXPORT CVReturn um_dlCreate(UMLinkRef *out) __asm("_CVDisplayLinkCreateWithActiveCGDisplays");
UM_EXPORT CVReturn um_dlCreate(UMLinkRef *out) {
    UMDisplayLink *d = [UMDisplayLink new]; double f = 60; MacShimScreenInfo(0, 0, 0, &f); d->period = 1.0 / (f > 0 ? f : 60);
    if (out) *out = (__bridge_retained void *)d;
    UMLog(@"CVDisplayLink created (%.0f Hz)", f);
    return kCVReturnSuccess;
}
UM_EXPORT CVReturn um_dlCreateDisplay(uint32_t display, UMLinkRef *out) __asm("_CVDisplayLinkCreateWithCGDisplay");
UM_EXPORT CVReturn um_dlCreateDisplay(uint32_t display, UMLinkRef *out) { return um_dlCreate(out); }
UM_EXPORT CVReturn um_dlSetDisplay(UMLinkRef l, uint32_t display) __asm("_CVDisplayLinkSetCurrentCGDisplay");
UM_EXPORT CVReturn um_dlSetDisplay(UMLinkRef l, uint32_t display) { return kCVReturnSuccess; }
UM_EXPORT CVReturn um_dlSetCallback(UMLinkRef l, UMLinkCallback cb, void *ctx) __asm("_CVDisplayLinkSetOutputCallback");
UM_EXPORT CVReturn um_dlSetCallback(UMLinkRef l, UMLinkCallback cb, void *ctx) { UMDisplayLink *d = UMDL(l); d->cb = cb; d->ctx = ctx; return kCVReturnSuccess; }
UM_EXPORT CVReturn um_dlStart(UMLinkRef l) __asm("_CVDisplayLinkStart");
UM_EXPORT CVReturn um_dlStart(UMLinkRef l) {
    UMDisplayLink *d = UMDL(l); if (d->running) return kCVReturnSuccess;
    d->running = YES; d->thread = [[NSThread alloc] initWithTarget:d selector:@selector(threadMain) object:nil];
    d->thread.name = @"CVDisplayLink"; [d->thread start]; return kCVReturnSuccess;
}
UM_EXPORT CVReturn um_dlStop(UMLinkRef l) __asm("_CVDisplayLinkStop");
UM_EXPORT CVReturn um_dlStop(UMLinkRef l) { UMDisplayLink *d = UMDL(l); d->running = NO; [d->thread cancel]; d->thread = nil; return kCVReturnSuccess; }
UM_EXPORT void um_dlRelease(UMLinkRef l) __asm("_CVDisplayLinkRelease");
UM_EXPORT void um_dlRelease(UMLinkRef l) { if (!l) return; um_dlStop(l); UMDisplayLink *d = (__bridge_transfer UMDisplayLink *)l; (void)d; }
UM_EXPORT CVTime um_dlNominal(UMLinkRef l) __asm("_CVDisplayLinkGetNominalOutputVideoRefreshPeriod");
UM_EXPORT CVTime um_dlNominal(UMLinkRef l) { double f = 60; MacShimScreenInfo(0, 0, 0, &f); CVTime t = { 1, (int32_t)(f > 0 ? f : 60), 0 }; return t; }
UM_EXPORT double um_dlActual(UMLinkRef l) __asm("_CVDisplayLinkGetActualOutputVideoRefreshPeriod");
UM_EXPORT double um_dlActual(UMLinkRef l) { return l ? UMDL(l)->period : 1.0 / 60; }
/* OpenGL texture caches: no OpenGL on iOS */
UM_EXPORT CVReturn um_glCacheCreate(void *a, void *ca, void *ctx, void *pix, void *ta, void **out) __asm("_CVOpenGLTextureCacheCreate");
UM_EXPORT CVReturn um_glCacheCreate(void *a, void *ca, void *ctx, void *pix, void *ta, void **out) { if (out) *out = NULL; return kCVReturnUnsupported; }
UM_EXPORT CVReturn um_glCacheTex(void *a, void *cache, void *img, void *attrs, void **out) __asm("_CVOpenGLTextureCacheCreateTextureFromImage");
UM_EXPORT CVReturn um_glCacheTex(void *a, void *cache, void *img, void *attrs, void **out) { if (out) *out = NULL; return kCVReturnUnsupported; }
UM_EXPORT void um_glCacheFlush(void *cache, CVOptionFlags o) __asm("_CVOpenGLTextureCacheFlush");
UM_EXPORT void um_glCacheFlush(void *cache, CVOptionFlags o) {}
UM_EXPORT void um_glCacheRelease(void *cache) __asm("_CVOpenGLTextureCacheRelease");
UM_EXPORT void um_glCacheRelease(void *cache) {}
UM_EXPORT uint32_t um_glTexName(void *t) __asm("_CVOpenGLTextureGetName");
UM_EXPORT uint32_t um_glTexName(void *t) { return 0; }
UM_EXPORT uint32_t um_glTexTarget(void *t) __asm("_CVOpenGLTextureGetTarget");
UM_EXPORT uint32_t um_glTexTarget(void *t) { return 0; }

/* ---------------------------------------------------------------- Metal: the Mac player's GPU checks
 * Unity's Mac player only creates its Metal device when the GPU reports the macOS feature sets / GPU families
 * (MTLFeatureSet_macOS_GPUFamily*, MTLGPUFamilyMac*). The same Apple GPU in an iPhone answers NO to those names, so
 * Unity fell back to its Null device and drew nothing (unity_player.log, 8th device run: "NullGfxDevice"). The macOS
 * sets (10000-10999) and the Mac / Mac Catalyst families answer YES; everything else is the GPU's real answer. */
static IMP o_supportsFeatureSet, o_supportsFamily;
static BOOL um_supportsFeatureSet(id self, SEL _cmd, NSUInteger set) {
    if (set >= 10000 && set < 11000) return YES;
    return ((BOOL (*)(id, SEL, NSUInteger))o_supportsFeatureSet)(self, _cmd, set);
}
static BOOL um_supportsFamily(id self, SEL _cmd, NSInteger family) {
    if (family == 2001 || family == 2002 || family == 4001 || family == 4002) return YES;    /* Mac1, Mac2, MacCatalyst1/2 */
    return ((BOOL (*)(id, SEL, NSInteger))o_supportsFamily)(self, _cmd, family);
}
/* MTLCopyAllDevices: macOS only, and MacShim.m only had the ...WithObserver variant. Unity dlsym's it and, finding
   nothing, counted zero GPUs -> Null device (9th device run). Copy rule: the array is returned retained. */
UM_EXPORT NSArray *um_MTLCopyAllDevices(void) __asm("_MTLCopyAllDevices");
UM_EXPORT NSArray *um_MTLCopyAllDevices(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    static int said; if (!said++) UMLog(@"MTLCopyAllDevices -> %@", d.name ?: @"no device");
    return (__bridge NSArray *)CFBridgingRetain(d ? @[ d ] : @[]);
}
static void UMMetalAsMac(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) { UMLog(@"no Metal device"); return; }
    Class C = object_getClass(dev);
    Method fs = class_getInstanceMethod(C, @selector(supportsFeatureSet:)), fam = class_getInstanceMethod(C, @selector(supportsFamily:));
    if (fs && !o_supportsFeatureSet) o_supportsFeatureSet = method_setImplementation(fs, (IMP)um_supportsFeatureSet);
    if (fam && !o_supportsFamily) o_supportsFamily = method_setImplementation(fam, (IMP)um_supportsFamily);
    UMLog(@"Metal device %@ (%@): macOS feature sets and Mac GPU families reported as supported", dev.name, NSStringFromClass(C));
}

/* ---------------------------------------------------------------- audio session (UnityShimC.c "audio") */
static void UMAudioUp(void) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
        [s setCategory:AVAudioSessionCategorySoloAmbient error:&e];               /* game audio: follows the silent switch */
        [s setPreferredSampleRate:48000 error:nil];
        [s setPreferredIOBufferDuration:512.0 / 48000 error:nil];
        if (![s setActive:YES error:&e]) UMLog(@"audio session not active: %@", e.localizedDescription);
        UMLog(@"audio session: %.0f Hz, %.1f ms buffer, %ld output channels", s.sampleRate, s.IOBufferDuration * 1000, (long)s.outputNumberOfChannels);
        [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            if ([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) [AVAudioSession.sharedInstance setActive:YES error:nil];
        }];
    });
}
double MacShimAudioSampleRate(void) { UMAudioUp(); double r = AVAudioSession.sharedInstance.sampleRate; return r > 0 ? r : 48000; }
void MacShimAudioSetBufferFrames(uint32_t frames) { UMAudioUp(); if (frames) [AVAudioSession.sharedInstance setPreferredIOBufferDuration:frames / MacShimAudioSampleRate() error:nil]; }

/* ---------------------------------------------------------------- NSBundle answers for Unity
 * UnityPlayer and GameAssembly see the main bundle as the Mac-style folder (bundlePath, executablePath); UIKit and the
 * shim keep the real app bundle. Decided by who calls (the return address's image). */
/* code ranges (__TEXT) of UnityPlayer and GameAssembly, recorded as they load: UIKit asks bundlePath constantly, so
   the check must be two compares, not a dladdr */
static _Atomic uintptr_t g_imgLo[2], g_imgHi[2];
static void UMImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info di; if (!dladdr(mh, &di) || !di.dli_fname) return;
    int k = strstr(di.dli_fname, "/UnityPlayer.dylib") ? 0 : strstr(di.dli_fname, "/GameAssembly.dylib") ? 1 : -1;
    if (k < 0) return;
    const struct load_command *lc = (const void *)((const struct mach_header_64 *)mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize))
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, "__TEXT")) {
            const struct segment_command_64 *s = (const void *)lc;
            g_imgLo[k] = s->vmaddr + slide; g_imgHi[k] = s->vmaddr + slide + s->vmsize;
        }
}
static BOOL UMFromUnity(void *ret) {
    uintptr_t a = (uintptr_t)ret;
    return (a >= g_imgLo[0] && a < g_imgHi[0]) || (a >= g_imgLo[1] && a < g_imgHi[1]);
}
/* the same from CoreFoundation: UnityPlayer's lazy bind of CFBundleCopyExecutableURL is pointed at this */
UM_EXPORT CFURLRef um_CFBundleCopyExecutableURL(CFBundleRef b) __asm("_CFBundleCopyExecutableURL");
UM_EXPORT CFURLRef um_CFBundleCopyExecutableURL(CFBundleRef b) {
    static CFURLRef (*real)(CFBundleRef);
    if (!real) real = (CFURLRef (*)(CFBundleRef))dlsym(dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY | RTLD_NOLOAD), "CFBundleCopyExecutableURL");
    if (b == CFBundleGetMainBundle() && UMFromUnity(__builtin_return_address(0)) && MacShimDataFolder())
        return CFBridgingRetain([NSURL fileURLWithPath:[MacShimMacAppRoot() stringByAppendingPathComponent:@"Contents/MacOS/Secret Legend"]]);
    return real ? real(b) : NULL;
}
static IMP o_bundlePath, o_executablePath;
static NSString *um_bundlePath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && UMFromUnity(__builtin_return_address(0)) && MacShimDataFolder()) return MacShimMacAppRoot();
    return ((NSString *(*)(id, SEL))o_bundlePath)(self, _cmd);
}
static NSString *um_executablePath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && UMFromUnity(__builtin_return_address(0)) && MacShimDataFolder())
        return [MacShimMacAppRoot() stringByAppendingPathComponent:@"Contents/MacOS/Secret Legend"];
    return ((NSString *(*)(id, SEL))o_executablePath)(self, _cmd);
}

__attribute__((constructor)) static void UMInit(void) {
    @autoreleasepool {
        _dyld_register_func_for_add_image(UMImageAdded);          /* also called for every image already loaded */
        UMMetalAsMac();
        Class B = NSBundle.class;
        o_bundlePath = method_setImplementation(class_getInstanceMethod(B, @selector(bundlePath)), (IMP)um_bundlePath);
        o_executablePath = method_setImplementation(class_getInstanceMethod(B, @selector(executablePath)), (IMP)um_executablePath);
        Class W = NSClassFromString(@"NSWindow");
        if (W) {
            class_addMethod(W, @selector(convertRectToScreen:), (IMP)UMToScreen, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");
            class_addMethod(W, @selector(convertRectFromScreen:), (IMP)UMFromScreen, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}");
            class_addMethod(W, @selector(convertPointToScreen:), (IMP)UMPointToScreen, "{CGPoint=dd}@:{CGPoint=dd}");
            class_addMethod(W, @selector(convertPointFromScreen:), (IMP)UMPointFromScreen, "{CGPoint=dd}@:{CGPoint=dd}");
            class_addMethod(W, @selector(mouseLocationOutsideOfEventStream), (IMP)UMMouseInWindow, "{CGPoint=dd}@:");
            const char *R = "{CGRect={CGPoint=dd}{CGSize=dd}}";
            char rr[96], rrs[96], rrq[96];
            snprintf(rr, sizeof rr, "%s@:%s", R, R); snprintf(rrs, sizeof rrs, "%s@:%sQ", R, R); snprintf(rrq, sizeof rrq, "%s@:%sQ", R, R);
            Class WM = object_getClass(W);                            /* class methods live on the metaclass */
            class_addMethod(WM, @selector(frameRectForContentRect:styleMask:), (IMP)UMSameRectStyle, rrs);
            class_addMethod(WM, @selector(contentRectForFrameRect:styleMask:), (IMP)UMSameRectStyle, rrs);
            class_addMethod(W, @selector(frameRectForContentRect:), (IMP)UMSameRect, rr);
            class_addMethod(W, @selector(convertRectToBacking:), (IMP)UMToBacking, rr);
            class_addMethod(W, @selector(convertRectFromBacking:), (IMP)UMFromBacking, rr);
            class_addMethod(W, @selector(backingAlignedRect:options:), (IMP)UMBackingAligned, rrq);
            class_addMethod(W, @selector(occlusionState), (IMP)UMOcclusionVisible, "Q@:");
            class_addMethod(W, @selector(isVisible), (IMP)UMYes, "B@:");
            class_addMethod(W, @selector(isOnActiveSpace), (IMP)UMYes, "B@:");
        }
        Class V = NSClassFromString(@"NSView");
        if (V) {
            char pr[128]; snprintf(pr, sizeof pr, "B@:{CGPoint=dd}{CGRect={CGPoint=dd}{CGSize=dd}}");
            class_addMethod(V, @selector(mouse:inRect:), (IMP)UMMouseInRect, pr);
            class_addMethod(V, @selector(backingAlignedRect:options:), (IMP)UMBackingAligned, "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}Q");
        }
    }
}
