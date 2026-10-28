/*
 * TunicControls.m - the on-screen controller, the in-game "Phone Settings" gear panel, and the phone settings they share
 * with the start screen. Layout, look and rows follow the unity-ios-port mobile kit (TouchOverlay / TouchStyle /
 * PortSettingsPanel / SettingRows), rebuilt natively: Core Animation layers in the pad window above the game's Metal
 * layer, so presses, the press animation and the panel move at display rate whatever the game's frame rate.
 * Presses go into the virtual game controller (MacShim.m), which the game reads like a real Xbox pad.
 *
 * Settings (NSUserDefaults; Launcher.swift writes the same keys):
 *   PortScaling 0 Fit / 1 Stretch / 2 Stretch 1.943:1 (the game always renders 16:9: no Aspect Ratio setting, see TunicAspectValue)
 *   PortFrameRate 0..2 (30/60/120)
 *   PortTouchControls   PortTouchOpacity 20..100   PortTouchSize 70..150   PortFloatingStick   PortHaptics
 */
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>

extern void MacShimLogC(const char *what, const char *detail);
extern void MacShimPadButton(int b, BOOL down);
extern void MacShimPadDpad(int x, int y);
extern void MacShimPadStick(int right, float x, float y);
extern BOOL MacShimPadWanted(void);
extern BOOL MacShimGameDrawing(void);
extern GCExtendedGamepad *MacShimRealGamepad(void);
extern void MacShimBlockGameInput(BOOL blocked);
extern void MacShimApplyDisplay(void);
extern void MacShimSetFrameCap(int fps);

static void TCLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void TCLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    MacShimLogC("controls", s.UTF8String);
}

/* ================================================================ phone settings */
static NSString *const TCChanged = @"TunicSettingsChanged";
static NSUserDefaults *TD(void) { return NSUserDefaults.standardUserDefaults; }
__attribute__((constructor)) static void TCDefaults(void) {
    [TD() registerDefaults:@{ @"PortScaling": @0, @"PortFrameRate": @1, @"PortTouchControls": @YES,
                              @"PortTouchOpacity": @65, @"PortTouchSize": @100, @"PortFloatingStick": @NO, @"PortHaptics": @YES,
                              @"TunicResReadout": @NO }];
}
static NSInteger TCInt(NSString *k) { return [TD() integerForKey:k]; }
static BOOL TCBool(NSString *k) { return [TD() boolForKey:k]; }

static CGRect TCCentred(CGRect b, double a) {
    if (a <= 0 || b.size.width <= 0 || b.size.height <= 0) return b;
    double w = b.size.width, h = b.size.height;
    if (w / h > a) w = round(h * a); else h = round(w / a);
    return CGRectMake(b.origin.x + round((b.size.width - w) / 2), b.origin.y + round((b.size.height - h) / 2), w, h);
}
/* Screen Scaling: 0 Fit, 1 Stretch (the whole screen), 2 Stretch 1.943:1 (a centred 1.943:1 frame, the bars beside the
   Dynamic Island) */
BOOL TunicStretch(void) { NSInteger s = TCInt(@"PortScaling"); return s == 1 || s == 2; }
/* width:height the game renders at: always 16:9. Tunic never draws wider (its CameraResizer adds black side bars inside
   the picture on wider screens), so the kit's Aspect Ratio setting is left out: every shape it offered either matched
   16:9 or only made the picture smaller. Screen Scaling decides the shape on screen; nothing is spent on bars. */
double TunicAspectValue(void) { return 16.0 / 9.0; }
int TunicFrameCapSetting(void) { static const int f[] = { 30, 60, 120 }; NSInteger i = TCInt(@"PortFrameRate"); return f[i < 0 ? 0 : i > 2 ? 2 : i]; }
/* the game view inside the screen: the render shape, centred (the rest stays black) */
CGRect TunicGameRect(CGRect b) { return TCCentred(b, TunicAspectValue()); }
/* where a stretched picture goes: the whole screen, or the centred 1.943:1 frame */
CGRect TunicStretchRect(CGRect b) { return TCInt(@"PortScaling") == 2 ? TCCentred(b, 2106.0 / 1084.0) : b; }

/* ================================================================ look (TouchStyle) */
static UIColor *TCBody(CGFloat a) { return [UIColor colorWithRed:0.075 green:0.08 blue:0.10 alpha:a]; }   /* smoked glass */
static UIColor *TCNeutral(void) { return [UIColor colorWithRed:0.92 green:0.94 blue:1.0 alpha:1]; }
static UIColor *TCGreen(void)  { return [UIColor colorWithRed:0.36 green:0.80 blue:0.20 alpha:1]; }
static UIColor *TCRed(void)    { return [UIColor colorWithRed:0.93 green:0.24 blue:0.21 alpha:1]; }
static UIColor *TCBlue(void)   { return [UIColor colorWithRed:0.20 green:0.52 blue:0.96 alpha:1]; }
static UIColor *TCYellow(void) { return [UIColor colorWithRed:1.00 green:0.78 blue:0.15 alpha:1]; }

/* a polygon with rounded corners (triggers, the D-pad cross) */
static UIBezierPath *TCRoundedPolygon(const CGPoint *p, int n, CGFloat r) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (int i = 0; i < n; i++) {
        CGPoint a = p[(i + n - 1) % n], b = p[i], c = p[(i + 1) % n];
        CGFloat la = hypot(a.x - b.x, a.y - b.y), lc = hypot(c.x - b.x, c.y - b.y), rr = MIN(r, MIN(la, lc) / 2);
        CGPoint s = CGPointMake(b.x + (a.x - b.x) / la * rr, b.y + (a.y - b.y) / la * rr);
        CGPoint e = CGPointMake(b.x + (c.x - b.x) / lc * rr, b.y + (c.y - b.y) / lc * rr);
        if (i == 0) [path moveToPoint:s]; else [path addLineToPoint:s];
        [path addQuadCurveToPoint:e controlPoint:b];
    }
    [path closePath];
    return path;
}
/* SF Symbol drawn white into an image for a layer (View / Menu / gear / controller toggle) */
static CGImageRef TCSymbol(NSString *name, CGFloat pt) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightSemibold];
    UIImage *img = [[UIImage systemImageNamed:name withConfiguration:cfg] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!img) return NULL;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat]; f.opaque = NO;
    UIImage *r = [[[UIGraphicsImageRenderer alloc] initWithSize:img.size format:f] imageWithActions:^(UIGraphicsImageRendererContext *c) { [img drawAtPoint:CGPointZero]; }];
    return CGImageRetain(r.CGImage);                              /* caller releases */
}

/* ================================================================ controls */
typedef NS_ENUM(int, TCKind) { TCRound, TCPill, TCTrigger, TCDpad, TCStick, TCGear, TCToggle };
@interface TCControl : NSObject
@property TCKind kind; @property int button;                    /* MacShimPadButton id, -1 none */
@property CGPoint anchor, offset; @property CGSize size;        /* kit units: anchor (0,0) = bottom-left; offset/size on a 1080-high canvas, y up */
@property BOOL right, mirrored, colored; @property(copy) NSString *label, *icon; @property(strong) UIColor *accent;
@property(strong) CALayer *layer; @property(strong) CAShapeLayer *body, *rim, *knob, *knobRim;
@property(strong) NSArray<CAShapeLayer *> *arms;                 /* D-pad highlights: up, right, down, left */
@property CGPoint center, home; @property CGFloat radius;       /* points */
@property(weak) UITouch *touch; @property int dx, dy;
@end
@implementation TCControl @end

@class TunicPanel;
@interface TunicPadView : UIView
- (void)tcPanelClosed;
@end
@interface TunicPanel : UIView
@property(weak) TunicPadView *pad;
- (void)tcShow; - (void)tcHide; - (BOOL)tcOpen;
- (void)tcPadButton:(int)b down:(BOOL)d;                           /* on-screen pad presses navigate the panel */
- (void)tcPadDir:(int)x y:(int)y;
@end

@implementation TunicPadView {
    NSMutableArray<TCControl *> *_ctls; CALayer *_root; CADisplayLink *_link; BOOL _shown;
    CGSize _builtFor; UIEdgeInsets _builtInsets; NSInteger _builtSize; BOOL _builtFloating;
    UIImpactFeedbackGenerator *_hap; TunicPanel *_panel;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f]; if (!self) return nil;
    self.multipleTouchEnabled = YES; self.backgroundColor = UIColor.clearColor; self.hidden = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _ctls = [NSMutableArray array]; _root = [CALayer layer]; [self.layer addSublayer:_root];
    _hap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tcTick:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(10, 30, 30);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(tcSettingsChanged) name:TCChanged object:nil];
    return self;
}
- (void)setPanel:(TunicPanel *)p { _panel = p; }
- (void)tcSettingsChanged { _builtFor = CGSizeZero; [self setNeedsLayout]; [self tcTick:nil]; }
- (void)layoutSubviews { [super layoutSubviews]; [self tcBuildIfNeeded]; }

/* ---- the kit's layout (TouchOverlay.Build) */
- (TCControl *)tcAdd:(TCKind)k button:(int)b anchor:(CGPoint)a offset:(CGPoint)o size:(CGSize)s label:(NSString *)l icon:(NSString *)ic accent:(UIColor *)acc colored:(BOOL)col {
    TCControl *c = [TCControl new]; c.kind = k; c.button = b; c.anchor = a; c.offset = o; c.size = s; c.label = l; c.icon = ic;
    c.accent = acc ?: UIColor.whiteColor; c.colored = col; [_ctls addObject:c]; return c;
}
- (void)tcBuildIfNeeded {
    CGSize S = self.bounds.size; NSInteger size = TCInt(@"PortTouchSize"); BOOL fl = TCBool(@"PortFloatingStick");
    if (S.width <= 0 || (CGSizeEqualToSize(S, _builtFor) && UIEdgeInsetsEqualToEdgeInsets(self.safeAreaInsets, _builtInsets) && size == _builtSize && fl == _builtFloating)) return;
    /* fingers still down on the old layout let go first (the kit does the same) */
    for (TCControl *c in _ctls) if (c.touch) [self tcRelease:c];
    _builtFor = S; _builtInsets = self.safeAreaInsets; _builtSize = size; _builtFloating = fl;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *l in [_root.sublayers copy]) [l removeFromSuperlayer];
    [_ctls removeAllObjects];
    CGPoint BL = { 0, 0 }, BR = { 1, 0 }, TL = { 0, 1 }, TR = { 1, 1 }, TC = { 0.5, 1 };
    [self tcAdd:TCStick button:-1 anchor:BL offset:CGPointMake(290, 260) size:CGSizeMake(270, 270) label:nil icon:nil accent:nil colored:NO];
    [self tcAdd:TCDpad button:-1 anchor:BL offset:CGPointMake(255, 620) size:CGSizeMake(230, 230) label:nil icon:nil accent:nil colored:NO];
    [self tcAdd:TCStick button:-1 anchor:BR offset:CGPointMake(-575, 175) size:CGSizeMake(184, 184) label:nil icon:nil accent:nil colored:NO].right = YES;
    CGFloat fb = 124, sp = 108; CGPoint c0 = { -270, 290 };
    [self tcAdd:TCRound button:0 anchor:BR offset:CGPointMake(c0.x, c0.y - sp) size:CGSizeMake(fb, fb) label:@"A" icon:nil accent:TCGreen() colored:YES];
    [self tcAdd:TCRound button:1 anchor:BR offset:CGPointMake(c0.x + sp, c0.y) size:CGSizeMake(fb, fb) label:@"B" icon:nil accent:TCRed() colored:YES];
    [self tcAdd:TCRound button:2 anchor:BR offset:CGPointMake(c0.x - sp, c0.y) size:CGSizeMake(fb, fb) label:@"X" icon:nil accent:TCBlue() colored:YES];
    [self tcAdd:TCRound button:3 anchor:BR offset:CGPointMake(c0.x, c0.y + sp) size:CGSizeMake(fb, fb) label:@"Y" icon:nil accent:TCYellow() colored:YES];
    [self tcAdd:TCPill button:4 anchor:TL offset:CGPointMake(165, -95) size:CGSizeMake(210, 84) label:@"LB" icon:nil accent:nil colored:NO];
    [self tcAdd:TCTrigger button:6 anchor:TL offset:CGPointMake(395, -100) size:CGSizeMake(150, 112) label:@"LT" icon:nil accent:nil colored:NO];
    [self tcAdd:TCPill button:5 anchor:TR offset:CGPointMake(-165, -95) size:CGSizeMake(210, 84) label:@"RB" icon:nil accent:nil colored:NO];
    [self tcAdd:TCTrigger button:7 anchor:TR offset:CGPointMake(-395, -100) size:CGSizeMake(150, 112) label:@"RT" icon:nil accent:nil colored:NO].mirrored = YES;
    [self tcAdd:TCRound button:10 anchor:TC offset:CGPointMake(-85, -72) size:CGSizeMake(80, 80) label:nil icon:@"rectangle.on.rectangle" accent:nil colored:NO];
    [self tcAdd:TCRound button:11 anchor:TC offset:CGPointMake(85, -72) size:CGSizeMake(80, 80) label:nil icon:@"line.3.horizontal" accent:nil colored:NO];
    [self tcAdd:TCRound button:8 anchor:BL offset:CGPointMake(510, 120) size:CGSizeMake(76, 76) label:@"L3" icon:nil accent:nil colored:NO];
    [self tcAdd:TCRound button:9 anchor:BR offset:CGPointMake(-575, 355) size:CGSizeMake(76, 76) label:@"R3" icon:nil accent:nil colored:NO];
    [self tcAdd:TCGear button:-1 anchor:TC offset:CGPointMake(255, -72) size:CGSizeMake(68, 68) label:nil icon:@"gearshape.fill" accent:nil colored:NO];
    /* CyPort's show/hide pad button, kept: mirrors the gear */
    [self tcAdd:TCToggle button:-1 anchor:TC offset:CGPointMake(-255, -72) size:CGSizeMake(68, 68) label:nil icon:@"gamecontroller" accent:nil colored:NO];
    CGRect sa = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat u = sa.size.height / 1080.0 * size / 100.0;          /* kit: 1080-high canvas in the safe area, x Touch Size */
    for (TCControl *c in _ctls) {
        CGPoint p = CGPointMake(sa.origin.x + c.anchor.x * sa.size.width + c.offset.x * u,
                                CGRectGetMaxY(sa) - c.anchor.y * sa.size.height - c.offset.y * u);
        CGSize s = CGSizeMake(c.size.width * u, c.size.height * u);
        c.center = c.home = p; c.radius = MAX(s.width, s.height) / 2;
        [self tcDraw:c size:s];
    }
    [CATransaction commit];
    [self tcApplyVisibility];
}
- (void)tcDraw:(TCControl *)c size:(CGSize)s {
    CALayer *L = [CALayer layer]; L.bounds = CGRectMake(0, 0, s.width, s.height); L.position = c.center; c.layer = L; [_root addSublayer:L];
    CGRect b = L.bounds; CGFloat lw = MAX(1, MIN(s.width, s.height) * 0.022);
    UIBezierPath *shape;
    switch (c.kind) {
        case TCPill: shape = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, lw, lw) cornerRadius:s.height * 0.38]; break;
        case TCTrigger: {                                         /* taller on the outer side, like a real trigger */
            CGFloat w = s.width, h = s.height, in = lw;
            CGPoint p[4] = { { in, in }, { w - in, h * 0.24 }, { w - in, h - in }, { in, h - in } };
            if (c.mirrored) for (int i = 0; i < 4; i++) p[i].x = w - p[i].x;
            if (c.mirrored) { CGPoint t = p[0]; p[0] = p[1]; p[1] = t; t = p[2]; p[2] = p[3]; p[3] = t; }
            shape = TCRoundedPolygon(p, 4, h * 0.22); break;
        }
        case TCDpad: {
            CGFloat w = s.width, a = w * 0.34, lo = (w - a) / 2, hi = (w + a) / 2, in = lw;
            CGPoint p[12] = { { lo, in }, { hi, in }, { hi, lo }, { w - in, lo }, { w - in, hi }, { hi, hi },
                              { hi, w - in }, { lo, w - in }, { lo, hi }, { in, hi }, { in, lo }, { lo, lo } };
            shape = TCRoundedPolygon(p, 12, a * 0.22); break;
        }
        default: shape = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(b, lw, lw)]; break;
    }
    BOOL stick = c.kind == TCStick;
    CAShapeLayer *body = [CAShapeLayer layer]; body.path = shape.CGPath; body.fillColor = TCBody(stick ? 0.42 : 0.66).CGColor; [L addSublayer:body]; c.body = body;
    /* top shine: light falls from above, as in the kit's art */
    CAGradientLayer *shine = [CAGradientLayer layer]; shine.frame = b;
    shine.colors = @[ (id)[UIColor colorWithWhite:1 alpha:0.16].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor ];
    shine.endPoint = CGPointMake(0.5, 0.55); CAShapeLayer *m = [CAShapeLayer layer]; m.path = shape.CGPath; shine.mask = m; [L addSublayer:shine];
    CAShapeLayer *rim = [CAShapeLayer layer]; rim.path = shape.CGPath; rim.fillColor = nil; rim.lineWidth = lw;
    rim.strokeColor = [UIColor colorWithWhite:1 alpha:0.34].CGColor; [L addSublayer:rim]; c.rim = rim;
    if (c.kind == TCRound || stick) {                            /* inner ring */
        CGFloat k = stick ? 0.30 : 0.09; CAShapeLayer *in = [CAShapeLayer layer];
        in.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(b, s.width * k, s.height * k)].CGPath; in.fillColor = nil;
        in.lineWidth = MAX(0.75, lw * 0.6); in.strokeColor = [UIColor colorWithWhite:1 alpha:stick ? 0.10 : 0.08].CGColor; [L addSublayer:in];
    }
    if (c.kind == TCDpad) {                                      /* arrows + press highlights per arm */
        CGFloat w = s.width, a = w * 0.34, lo = (w - a) / 2, hi = (w + a) / 2, t = a * 0.22;
        NSMutableArray *arms = [NSMutableArray array];
        CGRect armR[4] = { CGRectMake(lo, lw, a, lo - lw), CGRectMake(hi, lo, w - hi - lw, a), CGRectMake(lo, hi, a, w - hi - lw), CGRectMake(lw, lo, lo - lw, a) };
        CGPoint tip[4] = { { w / 2, lo * 0.38 }, { w - lo * 0.38, w / 2 }, { w / 2, w - lo * 0.38 }, { lo * 0.38, w / 2 } };
        for (int i = 0; i < 4; i++) {
            CAShapeLayer *h = [CAShapeLayer layer]; h.path = [UIBezierPath bezierPathWithRoundedRect:armR[i] cornerRadius:a * 0.2].CGPath;
            h.fillColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor; h.hidden = YES; [L addSublayer:h]; [arms addObject:h];
            CGPoint q = tip[i]; CGFloat dx = (i == 1) - (i == 3), dy = (i == 2) - (i == 0);
            UIBezierPath *tri = [UIBezierPath bezierPath];
            [tri moveToPoint:CGPointMake(q.x + dx * t, q.y + dy * t)];
            [tri addLineToPoint:CGPointMake(q.x - dx * t * 0.6 - dy * t, q.y - dy * t * 0.6 + dx * t)];
            [tri addLineToPoint:CGPointMake(q.x - dx * t * 0.6 + dy * t, q.y - dy * t * 0.6 - dx * t)]; [tri closePath];
            CAShapeLayer *ar = [CAShapeLayer layer]; ar.path = tri.CGPath; ar.fillColor = [UIColor colorWithWhite:1 alpha:0.78].CGColor; [L addSublayer:ar];
        }
        c.arms = arms;
    }
    if (stick) {                                                 /* knob: diameter = radius x 1.05 (kit) */
        CGFloat kd = s.width / 2 * 1.05; CGRect kr = CGRectMake((s.width - kd) / 2, (s.height - kd) / 2, kd, kd);
        CAShapeLayer *k = [CAShapeLayer layer]; k.frame = b; k.path = [UIBezierPath bezierPathWithOvalInRect:kr].CGPath; k.fillColor = TCBody(0.86).CGColor;
        CAShapeLayer *kr2 = [CAShapeLayer layer]; kr2.frame = b; kr2.fillColor = nil; kr2.lineWidth = MAX(1, kd * 0.03);
        UIBezierPath *rings = [UIBezierPath bezierPathWithOvalInRect:kr]; [rings appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset(kr, kd * 0.17, kd * 0.17)]];
        kr2.path = rings.CGPath; kr2.strokeColor = [UIColor colorWithWhite:1 alpha:0.40].CGColor;
        [L addSublayer:k]; [L addSublayer:kr2]; c.knob = k; c.knobRim = kr2;
    }
    if (c.label) {
        CGFloat fs = MIN(s.width, s.height) * (c.kind == TCRound && c.label.length == 1 ? 0.44 : 0.34);
        CATextLayer *t = [CATextLayer layer]; t.contentsScale = UIScreen.mainScreen.scale; t.alignmentMode = kCAAlignmentCenter;
        UIFont *f = [UIFont systemFontOfSize:fs weight:UIFontWeightHeavy];
        t.font = (__bridge CFTypeRef)f; t.fontSize = fs; t.string = c.label;
        t.foregroundColor = (c.colored ? c.accent : TCNeutral()).CGColor;
        CGFloat dy = c.kind == TCTrigger ? s.height * 0.06 : 0;
        t.frame = CGRectMake(0, (s.height - f.lineHeight) / 2 + dy, s.width, f.lineHeight);
        t.shadowOpacity = 0.6; t.shadowRadius = 0; t.shadowOffset = CGSizeMake(0, fs * 0.04); t.shadowColor = UIColor.blackColor.CGColor;
        [L addSublayer:t];
    }
    if (c.icon) {
        CGFloat pt = s.width * 0.34; CGImageRef img = TCSymbol(c.icon, pt);
        if (img) {
            CALayer *i = [CALayer layer]; CGFloat iw = CGImageGetWidth(img) / UIScreen.mainScreen.scale, ih = CGImageGetHeight(img) / UIScreen.mainScreen.scale;
            i.contents = (__bridge id)img; i.contentsScale = UIScreen.mainScreen.scale; i.frame = CGRectMake((s.width - iw) / 2, (s.height - ih) / 2, iw, ih);
            i.opacity = 0.92; [L addSublayer:i]; CGImageRelease(img);
        }
    }
    L.shadowColor = c.accent.CGColor; L.shadowOpacity = 0; L.shadowRadius = MIN(s.width, s.height) * 0.16; L.shadowOffset = CGSizeZero;
    L.shadowPath = shape.CGPath;
}

/* ---- visibility: the game draws, no real controller (then only the gear stays), Touch Controls on */
- (BOOL)tcControlsOn { return TCBool(@"PortTouchControls"); }
- (BOOL)tcIsUtility:(TCControl *)c { return c.kind == TCGear || c.kind == TCToggle; }
- (void)tcApplyVisibility {
    BOOL padWanted = MacShimPadWanted(), on = [self tcControlsOn];
    [CATransaction begin]; [CATransaction setAnimationDuration:0.2];
    _root.opacity = (float)(TCInt(@"PortTouchOpacity") / 100.0);
    for (TCControl *c in _ctls) {
        BOOL vis = c.kind == TCGear ? YES : c.kind == TCToggle ? padWanted : padWanted && on;
        c.layer.hidden = !vis;
        c.layer.opacity = [self tcIsUtility:c] && (!on || !padWanted) ? 0.55 : 1;
    }
    [CATransaction commit];
}
- (void)tcTick:(CADisplayLink *)l {
    BOOL want = MacShimGameDrawing();
    if (want != _shown) {
        _shown = want; self.hidden = !want;
        if (want) { TCLog(@"touch controls shown (kit layout, size %ld%%, opacity %ld%%)", (long)TCInt(@"PortTouchSize"), (long)TCInt(@"PortTouchOpacity")); [_hap prepare]; }
    }
    if (!want) return;
    [self tcBuildIfNeeded];
    static BOOL lastPad = -1, lastOn = -1; static NSInteger lastOp = -1;
    BOOL pad = MacShimPadWanted(), on = [self tcControlsOn]; NSInteger op = TCInt(@"PortTouchOpacity");
    if (pad != lastPad || on != lastOn || op != lastOp) {
        lastPad = pad; lastOn = on; lastOp = op;
        if (!pad || !on) for (TCControl *c in _ctls) if (c.touch && ![self tcIsUtility:c]) [self tcRelease:c];
        [self tcApplyVisibility];
    }
}

/* ---- touches */
- (BOOL)tcActive:(TCControl *)c { return !c.layer.hidden; }
- (TCControl *)tcControlAt:(CGPoint)p {
    TCControl *best = nil; CGFloat bestD = CGFLOAT_MAX;
    for (TCControl *c in _ctls) {
        if (![self tcActive:c]) continue;
        CGFloat r = c.radius * 1.18, d = hypot(p.x - c.home.x, p.y - c.home.y);    /* kit HitScale 1.18 */
        if (d <= r && d < bestD) { best = c; bestD = d; }
    }
    return best;
}
- (TCControl *)tcLeftStick { for (TCControl *c in _ctls) if (c.kind == TCStick && !c.right) return c; return nil; }
- (BOOL)tcInFloatingZone:(CGPoint)p {
    if (!TCBool(@"PortFloatingStick")) return NO;
    TCControl *ls = [self tcLeftStick]; if (!ls || ![self tcActive:ls]) return NO;
    CGRect sa = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);                 /* kit: 0-40 % wide, bottom 58 % */
    return p.x >= sa.origin.x && p.x <= sa.origin.x + sa.size.width * 0.40 && p.y >= CGRectGetMaxY(sa) - sa.size.height * 0.58;
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    if (self.hidden) return nil;
    if ([self tcControlAt:p] || [self tcInFloatingZone:p]) return self;
    return nil;                                                  /* the rest of the screen: the panel or the game */
}
- (void)tcHaptic { if (TCBool(@"PortHaptics")) { [_hap impactOccurredWithIntensity:0.75]; [_hap prepare]; } }
- (void)tcPressed:(TCControl *)c on:(BOOL)on {
    [CATransaction begin]; [CATransaction setAnimationDuration:on ? 0.06 : 0.14];
    c.layer.transform = on ? CATransform3DMakeScale(0.92, 0.92, 1) : CATransform3DIdentity;
    c.layer.shadowOpacity = on && c.colored ? 0.85 : 0;
    UIColor *pressFill = c.colored ? [c.accent colorWithAlphaComponent:0.55] : [UIColor colorWithWhite:0.32 alpha:0.75];
    if (c.kind != TCStick && c.kind != TCDpad) c.body.fillColor = (on ? pressFill : TCBody(0.66)).CGColor;
    [CATransaction commit];
}
- (void)tcButton:(TCControl *)c down:(BOOL)d {
    if (_panel.tcOpen) { [_panel tcPadButton:c.button down:d]; return; }      /* panel open: the pad navigates it */
    MacShimPadButton(c.button, d);
}
- (void)tcStick:(TCControl *)c to:(CGPoint)p {
    CGFloat R = c.radius, dx = p.x - c.center.x, dy = p.y - c.center.y, len = hypot(dx, dy), k = len > R ? R / len : 1;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    c.knob.position = CGPointMake(c.layer.bounds.size.width / 2 + dx * k, c.layer.bounds.size.height / 2 + dy * k);
    c.knobRim.position = c.knob.position; [CATransaction commit];
    float x = (float)(dx * k / R), y = (float)(-dy * k / R);
    if (c.right) {                                               /* start screen's Look sensitivity scales the right stick */
        double sens = [TD() doubleForKey:@"CyPortLookSensitivity"]; if (sens < 0.25 || sens > 4) sens = 1.5;
        float m = hypotf(x, y), want = fminf(1, m * (float)sens);
        if (m > 0.0001f) { x = x / m * want; y = y / m * want; }
    }
    if (_panel.tcOpen) { if (!c.right) [_panel tcPadDir:(x > 0.5) - (x < -0.5) y:(y > 0.5) - (y < -0.5)]; return; }
    MacShimPadStick(c.right, x, y);
}
- (void)tcDpad:(TCControl *)c at:(CGPoint)p {
    CGFloat dx = p.x - c.center.x, dy = p.y - c.center.y, R = c.radius, dead = R * 0.22;
    int x = 0, y = 0;
    if (hypot(dx, dy) > dead) {                                  /* 8-way: diagonals within 22.5 deg of 45 */
        double a = atan2(-dy, dx); int oct = (int)lround(a / (M_PI / 4)); oct = (oct + 8) % 8;
        static const int ox[8] = { 1, 1, 0, -1, -1, -1, 0, 1 }, oy[8] = { 0, 1, 1, 1, 0, -1, -1, -1 };
        x = ox[oct]; y = oy[oct];
    }
    if (x == c.dx && y == c.dy) return;
    if (x || y) [self tcHaptic];
    c.dx = x; c.dy = y;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    c.arms[0].hidden = y <= 0; c.arms[1].hidden = x <= 0; c.arms[2].hidden = y >= 0; c.arms[3].hidden = x >= 0;
    [CATransaction commit];
    if (_panel.tcOpen) { [_panel tcPadDir:x y:y]; return; }
    MacShimPadDpad(x, y);
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self]; TCControl *c = [self tcControlAt:p];
        if (!c && [self tcInFloatingZone:p]) {                    /* floating left stick: it comes to the thumb */
            c = [self tcLeftStick];
            if (c && !c.touch) { [CATransaction begin]; [CATransaction setDisableActions:YES]; c.center = p; c.layer.position = p; [CATransaction commit]; }
        }
        if (!c || c.touch) continue;
        c.touch = t;
        switch (c.kind) {
            case TCGear: [self tcHaptic]; [self tcPressed:c on:YES]; break;
            case TCToggle: [self tcHaptic]; [self tcPressed:c on:YES]; break;
            case TCDpad: [self tcDpad:c at:p]; break;
            case TCStick: [self tcStick:c to:p]; break;
            default: [self tcHaptic]; [self tcPressed:c on:YES]; [self tcButton:c down:YES]; break;
        }
    }
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        for (TCControl *c in _ctls) {
            if (c.touch != t) continue;
            if (c.kind == TCStick) [self tcStick:c to:p];
            else if (c.kind == TCDpad) [self tcDpad:c at:p];
            else if (hypot(p.x - c.home.x, p.y - c.home.y) > c.radius * 1.7) [self tcRelease:c];   /* slid off: let go */
        }
    }
}
- (void)tcRelease:(TCControl *)c {
    TCKind k = c.kind; c.touch = nil;
    if (k == TCStick) {
        [self tcStick:c to:c.center];
        if (!c.right && TCBool(@"PortFloatingStick")) { [CATransaction begin]; [CATransaction setDisableActions:YES]; c.center = c.home; c.layer.position = c.home; [CATransaction commit]; }
    } else if (k == TCDpad) [self tcDpad:c at:c.center];
    else { [self tcPressed:c on:NO]; if (k != TCGear && k != TCToggle) [self tcButton:c down:NO]; }
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts)
        for (TCControl *c in [_ctls copy]) {
            if (c.touch != t) continue;
            BOOL tap = hypot([t locationInView:self].x - c.home.x, [t locationInView:self].y - c.home.y) <= c.radius * 1.7;
            TCKind k = c.kind; [self tcRelease:c];
            if (tap && k == TCGear) { if (_panel.tcOpen) [_panel tcHide]; else [_panel tcShow]; }
            if (tap && k == TCToggle) {                          /* CyPort's pad toggle = the Touch Controls setting */
                [TD() setBool:![self tcControlsOn] forKey:@"PortTouchControls"];
                TCLog(@"touch controls %@ (pad button)", [self tcControlsOn] ? @"on" : @"off");
                [NSNotificationCenter.defaultCenter postNotificationName:TCChanged object:nil];
            }
        }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) for (TCControl *c in [_ctls copy]) if (c.touch == t) [self tcRelease:c];
}
- (void)tcPanelClosed { for (TCControl *c in _ctls) if (c.touch && ![self tcIsUtility:c]) [self tcRelease:c]; }
@end

/* ================================================================ Phone Settings panel (PortSettingsPanel) */
@interface TCRow : NSObject
@property(copy) NSString *title; @property(copy) NSArray<NSString *> *values; @property(copy) NSInteger (^get)(void); @property(copy) void (^set)(NSInteger);
@property(strong) UIView *view; @property(strong) UILabel *label, *value; @property(strong) CAShapeLayer *bg;
@end
@implementation TCRow @end

static NSArray<NSString *> *TCPercent(int from, int to, int step) {
    NSMutableArray *a = [NSMutableArray array]; for (int v = from; v <= to; v += step) [a addObject:[NSString stringWithFormat:@"%d%%", v]]; return a;
}

@implementation TunicPanel {
    UIView *_card; UIScrollView *_scroll; NSArray<TCRow *> *_rows; NSInteger _sel; BOOL _open;
    CADisplayLink *_link; int _heldDir; double _nextRepeat; BOOL _hadA, _hadB, _hadMenu;
    UISelectionFeedbackGenerator *_tick;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f]; if (!self) return nil;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55]; self.hidden = YES; self.alpha = 0;
    _tick = [UISelectionFeedbackGenerator new];
    _card = [UIView new]; _card.backgroundColor = TCBody(0.94); _card.layer.cornerRadius = 26; _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor; _card.layer.borderWidth = 1; [self addSubview:_card];
    UILabel *title = [UILabel new]; title.text = @"Phone Settings"; title.textColor = TCNeutral(); title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightSemibold]; title.tag = 1; [_card addSubview:title];
    UILabel *hint = [UILabel new]; hint.text = @"D-pad ▲▼ choose    ◀▶ change    B close"; hint.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; hint.textAlignment = NSTextAlignmentCenter; hint.tag = 2; [_card addSubview:hint];
    _scroll = [UIScrollView new]; _scroll.showsVerticalScrollIndicator = NO; _scroll.alwaysBounceVertical = YES; [_card addSubview:_scroll];
    [self tcBuildRows];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tcTap:)];
    tap.cancelsTouchesInView = NO; [self addGestureRecognizer:tap];         /* sees taps on the rows too; scrolling still works */
    return self;
}
- (BOOL)tcOpen { return _open; }
- (TCRow *)row:(NSString *)t values:(NSArray *)v get:(NSInteger (^)(void))g set:(void (^)(NSInteger))s { TCRow *r = [TCRow new]; r.title = t; r.values = v; r.get = g; r.set = s; return r; }
- (void)tcBuildRows {
    void (^display)(void) = ^{ MacShimApplyDisplay(); };
    void (^touch)(void) = ^{ [NSNotificationCenter.defaultCenter postNotificationName:TCChanged object:nil]; };
    NSArray *offOn = @[ @"Off", @"On" ];
    _rows = @[
        [self row:@"Screen Scaling" values:@[ @"Fit", @"Stretch", @"Stretch 1.943:1" ] get:^{ return TCInt(@"PortScaling"); } set:^(NSInteger i) { [TD() setInteger:i forKey:@"PortScaling"]; display(); }],
        [self row:@"Frame Rate" values:@[ @"30 FPS", @"60 FPS", @"120 FPS (ProMotion)" ] get:^{ return TCInt(@"PortFrameRate"); } set:^(NSInteger i) { [TD() setInteger:i forKey:@"PortFrameRate"]; MacShimSetFrameCap(TunicFrameCapSetting()); }],
        [self row:@"Touch Controls" values:offOn get:^{ return (NSInteger)TCBool(@"PortTouchControls"); } set:^(NSInteger i) { [TD() setBool:i == 1 forKey:@"PortTouchControls"]; touch(); }],
        [self row:@"Touch Opacity" values:TCPercent(20, 100, 5) get:^{ return (TCInt(@"PortTouchOpacity") - 20) / 5; } set:^(NSInteger i) { [TD() setInteger:20 + i * 5 forKey:@"PortTouchOpacity"]; touch(); }],
        [self row:@"Touch Size" values:TCPercent(70, 150, 10) get:^{ return (TCInt(@"PortTouchSize") - 70) / 10; } set:^(NSInteger i) { [TD() setInteger:70 + i * 10 forKey:@"PortTouchSize"]; touch(); }],
        [self row:@"Left Stick" values:@[ @"Fixed", @"Floating" ] get:^{ return (NSInteger)TCBool(@"PortFloatingStick"); } set:^(NSInteger i) { [TD() setBool:i == 1 forKey:@"PortFloatingStick"]; touch(); }],
        [self row:@"Vibration" values:offOn get:^{ return (NSInteger)TCBool(@"PortHaptics"); } set:^(NSInteger i) { [TD() setBool:i == 1 forKey:@"PortHaptics"]; touch(); }],
        [self row:@"Resolution Readout" values:offOn get:^{ return (NSInteger)TCBool(@"TunicResReadout"); } set:^(NSInteger i) { [TD() setBool:i == 1 forKey:@"TunicResReadout"]; }],
    ];
    for (TCRow *r in _rows) {
        r.view = [UIView new]; [_scroll addSubview:r.view];
        r.bg = [CAShapeLayer layer]; r.bg.lineWidth = 1; [r.view.layer addSublayer:r.bg];
        r.label = [UILabel new]; r.label.text = r.title; r.label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium]; [r.view addSubview:r.label];
        r.value = [UILabel new]; r.value.textAlignment = NSTextAlignmentCenter; r.value.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold];
        r.value.textColor = UIColor.whiteColor; r.value.adjustsFontSizeToFitWidth = YES; r.value.minimumScaleFactor = 0.7; [r.view addSubview:r.value];
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect sa = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat rowH = 44, gap = 8, cw = MIN(560, sa.size.width - 40), head = 54, foot = 36;
    CGFloat ch = MIN(sa.size.height - 24, head + foot + _rows.count * (rowH + gap));
    _card.frame = CGRectMake(CGRectGetMidX(sa) - cw / 2, CGRectGetMidY(sa) - ch / 2, cw, ch);
    [_card viewWithTag:1].frame = CGRectMake(0, 12, cw, 30);
    [_card viewWithTag:2].frame = CGRectMake(0, ch - foot + 4, cw, 24);
    _scroll.frame = CGRectMake(16, head, cw - 32, ch - head - foot);
    _scroll.contentSize = CGSizeMake(cw - 32, _rows.count * (rowH + gap) - gap);
    for (NSUInteger i = 0; i < _rows.count; i++) {
        TCRow *r = _rows[i]; CGFloat w = cw - 32;
        r.view.frame = CGRectMake(0, i * (rowH + gap), w, rowH);
        r.bg.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, w - 1, rowH - 1) cornerRadius:rowH * 0.38].CGPath;
        r.label.frame = CGRectMake(16, 0, w * 0.42, rowH);
        r.value.frame = CGRectMake(w * 0.42, 0, w * 0.58 - 12, rowH);
    }
    [self tcPaint];
}
- (void)tcPaint {
    for (NSUInteger i = 0; i < _rows.count; i++) {
        TCRow *r = _rows[i]; BOOL sel = (NSInteger)i == _sel;
        NSInteger v = MAX(0, MIN((NSInteger)r.values.count - 1, r.get()));
        r.value.text = [NSString stringWithFormat:@"◀   %@   ▶", r.values[v]];
        r.bg.fillColor = (sel ? [UIColor colorWithRed:0.30 green:0.33 blue:0.40 alpha:0.95] : [UIColor colorWithWhite:1 alpha:0.06]).CGColor;
        r.bg.strokeColor = (sel ? [TCGreen() colorWithAlphaComponent:0.9] : [UIColor colorWithWhite:1 alpha:0.10]).CGColor;
        r.label.textColor = sel ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.82];
    }
}
- (void)tcSelect:(NSInteger)i {
    i = MAX(0, MIN((NSInteger)_rows.count - 1, i)); if (i == _sel) return; _sel = i; [_tick selectionChanged]; [self tcPaint];
    CGRect f = _rows[i].view.frame; [_scroll scrollRectToVisible:CGRectInset(f, 0, -10) animated:YES];
}
- (void)tcChange:(NSInteger)d {
    TCRow *r = _rows[_sel]; NSInteger n = r.values.count, v = MAX(0, MIN(n - 1, r.get()));
    NSInteger nv = ((v + d) % n + n) % n; r.set(nv); [_tick selectionChanged]; [self tcPaint];
    TCLog(@"Phone Settings: %@ -> %@", r.title, r.values[nv]);
}
- (void)tcShow {
    if (_open) return; _open = YES; [self tcPaint]; self.hidden = NO; [self.superview bringSubviewToFront:self];
    [self.superview bringSubviewToFront:(UIView *)self.pad];        /* the pad stays on top: its D-pad and buttons drive the panel */
    MacShimBlockGameInput(YES);
    _card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ self.alpha = 1; self->_card.transform = CGAffineTransformIdentity; } completion:nil];
    GCExtendedGamepad *g = MacShimRealGamepad(); _hadA = g.buttonA.isPressed; _hadB = g.buttonB.isPressed; _hadMenu = g.buttonMenu.isPressed;
    _heldDir = 0;
    if (!_link) { _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tcPoll:)]; [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes]; }
    _link.paused = NO;
}
- (void)tcHide {
    if (!_open) return; _open = NO; _link.paused = YES;
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{ self.alpha = 0; self->_card.transform = CGAffineTransformMakeScale(0.97, 0.97); }
                     completion:^(BOOL done) { if (!self->_open) self.hidden = YES; }];
    [self.pad tcPanelClosed];
    MacShimBlockGameInput(NO);
}
/* touches: a row = select it; its value's left / right half = previous / next; outside the card = close */
- (void)tcTap:(UITapGestureRecognizer *)g {
    if (!_open) return;
    CGPoint p = [g locationInView:_card];
    if (![_card pointInside:p withEvent:nil]) { [self tcHide]; return; }
    CGPoint q = [g locationInView:_scroll];
    for (NSUInteger i = 0; i < _rows.count; i++) {
        TCRow *r = _rows[i]; if (!CGRectContainsPoint(r.view.frame, q)) continue;
        [self tcSelect:i];
        CGPoint v = [g locationInView:r.value];
        if ([r.value pointInside:v withEvent:nil]) [self tcChange:v.x < r.value.bounds.size.width / 2 ? -1 : 1];
        return;
    }
}
/* the on-screen pad while the panel is open */
- (void)tcPadButton:(int)b down:(BOOL)d {
    if (!d) return;
    if (b == 1 || b == 11) [self tcHide]; else if (b == 0) [self tcChange:1];
}
- (void)tcPadDir:(int)x y:(int)y { [self tcDir:(y > 0 ? 1 : y < 0 ? 2 : x < 0 ? 3 : x > 0 ? 4 : 0) now:CACurrentMediaTime()]; }
- (void)tcDir:(int)dir now:(double)now {                         /* 1 up 2 down 3 left 4 right; repeat while held */
    if (dir != _heldDir) { _heldDir = dir; _nextRepeat = now + 0.4; if (dir) [self tcStep:dir]; return; }
    if (dir && now >= _nextRepeat) { _nextRepeat = now + 0.11; [self tcStep:dir]; }
}
- (void)tcStep:(int)dir {
    if (dir == 1) [self tcSelect:_sel - 1]; else if (dir == 2) [self tcSelect:_sel + 1];
    else if (dir == 3) [self tcChange:-1]; else if (dir == 4) [self tcChange:1];
}
/* a real controller, polled at display rate (the game doesn't get it while the panel is open) */
- (void)tcPoll:(CADisplayLink *)l {
    GCExtendedGamepad *g = MacShimRealGamepad(); if (!g) return;
    double now = CACurrentMediaTime();
    float x = g.dpad.xAxis.value + g.leftThumbstick.xAxis.value, y = g.dpad.yAxis.value + g.leftThumbstick.yAxis.value;
    int dir = y > 0.5 ? 1 : y < -0.5 ? 2 : x < -0.5 ? 3 : x > 0.5 ? 4 : 0;
    [self tcDir:dir now:now];
    BOOL a = g.buttonA.isPressed, b = g.buttonB.isPressed, m = g.buttonMenu.isPressed;
    if (a && !_hadA) [self tcChange:1];
    if ((b && !_hadB) || (m && !_hadMenu)) [self tcHide];
    _hadA = a; _hadB = b; _hadMenu = m;
}
@end

/* ================================================================ entry (MacShim.m MSTouchPadCreate) */
UIView *TunicPadCreate(UIView *parent) {
    TunicPanel *panel = [[TunicPanel alloc] initWithFrame:parent.bounds];
    TunicPadView *pad = [[TunicPadView alloc] initWithFrame:parent.bounds];
    [parent addSubview:panel]; [parent addSubview:pad];                    /* pad above the panel (kit: panel 940, controls 950) */
    panel.pad = pad; [pad setPanel:panel];
    TCLog(@"on-screen controller: mobile kit layout; Phone Settings behind the gear");
    return pad;
}
