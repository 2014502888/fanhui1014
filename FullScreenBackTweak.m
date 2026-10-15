// ============================================================================
//  FullScreenBack.m  —  万能全屏返回手势 (plain Objective-C, no Theos needed)
// ============================================================================
//  与同目录 tweak/FullScreenBack.x 功能完全一致的「零依赖」版本:
//  只使用 public Objective-C runtime API 做方法替换, 不依赖 Logos / Theos /
//  CydiaSubstrate, 因此可以用任意 clang + iOS SDK 直接编译成 dylib。
//
//  编译 (theos 可选):
//      xcrun -sdk iphoneos clang -arch arm64 -arch arm64e -dynamiclib \
//          -framework UIKit -framework Foundation -framework AudioToolbox \
//          -o FullScreenBack.dylib FullScreenBack.m -install_name @rpath/FullScreenBack.dylib
//
//  参考来源: WCPulse 1.7-4 的「全屏返回」+ FullScreenBackTweak, 本文件为独立重写。
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

// ---------------------------------------------------------------------------
// 1. 配置
// ---------------------------------------------------------------------------
static NSString *const kFSBEnabled  = @"fsb_enabled";
static NSString *const kFSBHaptic   = @"fsb_haptic";
static NSString *const kFSBStrength = @"fsb_strength";
static NSString *const kFSBDistance = @"fsb_distance";
static NSString *const kFSBLeftZone = @"fsb_left_zone";

static NSUserDefaults *FSBDefaults(void) { return [NSUserDefaults standardUserDefaults]; }

static BOOL FSBEnabled(void) {
    id v = [FSBDefaults() objectForKey:kFSBEnabled];
    return v ? [FSBDefaults() boolForKey:kFSBEnabled] : YES;
}
static BOOL FSBHapticOn(void) {
    id v = [FSBDefaults() objectForKey:kFSBHaptic];
    return v ? [FSBDefaults() boolForKey:kFSBHaptic] : YES;
}
static CGFloat FSBStrength(void) {
    id v = [FSBDefaults() objectForKey:kFSBStrength];
    if (!v) return 0.8;
    double d = [FSBDefaults() doubleForKey:kFSBStrength];
    if (d < 0.01) d = 0.01;
    if (d > 1.0) d = 1.0;
    return (CGFloat)d;
}
static CGFloat FSBDistance(void) {
    id v = [FSBDefaults() objectForKey:kFSBDistance];
    if (!v) return 0.35;
    double d = [FSBDefaults() doubleForKey:kFSBDistance];
    if (d < 0.05) d = 0.05;
    if (d > 0.95) d = 0.95;
    return (CGFloat)d;
}
// 左侧让位宽度: 系统自带的边缘返回手势在这个范围内更跟手, 我们让给它
static CGFloat FSBLeftZone(void) {
    id v = [FSBDefaults() objectForKey:kFSBLeftZone];
    if (!v) return 22.0;
    double d = [FSBDefaults() doubleForKey:kFSBLeftZone];
    if (d < 0.0) d = 0.0;
    if (d > 120.0) d = 120.0;
    return (CGFloat)d;
}

// ---------------------------------------------------------------------------
// 2. 触觉反馈
// ---------------------------------------------------------------------------
@interface FSBHaptics : NSObject
+ (instancetype)shared;
- (void)trackGesture:(UIPanGestureRecognizer *)g;
- (void)confirm;
@end

@implementation FSBHaptics {
    UIImpactFeedbackGenerator *_heavy;
    UISelectionFeedbackGenerator *_light;
    BOOL _crossed;
}
+ (instancetype)shared {
    static FSBHaptics *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBHaptics new]; });
    return s;
}
- (void)trackGesture:(UIPanGestureRecognizer *)g {
    if (!FSBHapticOn()) return;
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _heavy = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [_heavy prepare];
            _light = [UISelectionFeedbackGenerator new];
            [_light prepare];
            _crossed = NO;
            break;
        case UIGestureRecognizerStateChanged: {
            UIView *host = g.view;
            CGFloat w = host ? host.bounds.size.width : 0.0;
            if (w <= 0.0) break;
            CGFloat x = [g translationInView:host].x;
            if (x >= w * FSBDistance() && !_crossed) {
                _crossed = YES;
                [_light selectionChanged];
            } else if (x < w * FSBDistance()) {
                _crossed = NO;
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            UIView *host = g.view;
            CGFloat w = host ? host.bounds.size.width : 0.0;
            CGPoint tr = [g translationInView:host];
            CGPoint vel = [g velocityInView:host];
            BOOL passed = (w > 0.0 && tr.x > w * FSBDistance()) || (vel.x > 320.0 && tr.x > 8.0);
            if (passed) [self confirm];
            _heavy = nil; _light = nil; _crossed = NO;
            break;
        }
        default:
            _heavy = nil; _light = nil; _crossed = NO;
            break;
    }
}
- (void)confirm {
    if (!FSBHapticOn()) return;
    if (@available(iOS 13.0, *)) {
        UIImpactFeedbackGenerator *gen =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [gen impactOccurredWithIntensity:FSBStrength()];
        return;
    }
    AudioServicesPlaySystemSound(1519);
}
@end

// ---------------------------------------------------------------------------
// 3. 手势 / 代理
// ---------------------------------------------------------------------------
// 用独立子类标记我们自己的手势, 便于幂等判断 (不重复安装)
@interface FSBFullScreenPan : UIPanGestureRecognizer
@end
@implementation FSBFullScreenPan
@end

static UINavigationController *FSBNavForView(UIView *v) {
    UIResponder *r = v;
    while (r) {
        if ([r isKindOfClass:[UINavigationController class]]) return (UINavigationController *)r;
        if ([r isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)r;
            if (vc.navigationController) return vc.navigationController;
        }
        r = r.nextResponder;
    }
    return nil;
}

@interface FSBGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation FSBGestureDelegate
+ (instancetype)shared {
    static FSBGestureDelegate *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBGestureDelegate new]; });
    return s;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!FSBEnabled()) return NO;
    if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return NO;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)g;
    UINavigationController *nav = FSBNavForView(g.view);
    if (!nav) return NO;
    if (nav.viewControllers.count < 2) return NO;
    if (nav.transitionCoordinator != nil) return NO;    // 正在转场
    if (nav.presentedViewController != nil) return NO;  // 上面盖着模态
    if (nav.isBeingDismissed || nav.isBeingPresented) return NO;
    if (nav.interactivePopGestureRecognizer &&
        nav.interactivePopGestureRecognizer.enabled == NO) return NO;

    CGPoint t = [pan translationInView:pan.view];
    if (t.x <= 2.0) return NO;                       // 只认向右
    CGFloat ax = fabs(t.x), ay = fabs(t.y);
    if (ax <= ay) return NO;                         // 必须比纵向更横向
    if (ax > 0.0 && (ay / ax) > 0.98) return NO;     // 太斜不算
    // 判定规则与 tests/fsb_logic.h 一致, 由 tests/test_fsb_logic.py 覆盖

    // 左边缘让位给系统原生边缘手势 (它更早、更跟手)
    if ([pan locationInView:pan.view].x <= FSBLeftZone()) return NO;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    UIView *root = g.view;
    while (v && v != root) {
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            if (sv.contentSize.width > sv.bounds.size.width + 8.0) return NO; // 真能横滚
        }
        v = v.superview;
    }
    return YES;
}
@end

// ---------------------------------------------------------------------------
// 4. 安装
// ---------------------------------------------------------------------------
// 私有 selector 用字符串拼接, 避免在二进制里留下完整明文
static SEL FSBHandleTransitionSelector(void) {
    static SEL sel; static dispatch_once_t t;
    dispatch_once(&t, ^{
        NSString *name = [@[@"handle", @"Navigation", @"Transition:"] componentsJoinedByString:@""];
        sel = NSSelectorFromString(name);
    });
    return sel;
}

static id FSBSystemTransitionTarget(UINavigationController *nav) {
    UIGestureRecognizer *sys = nav.interactivePopGestureRecognizer;
    if (!sys) return nil;

    @try {
        id targets = [sys valueForKey:@"_targets"];
        if ([targets isKindOfClass:[NSArray class]] && [targets count] > 0) {
            id wrapper = [targets objectAtIndex:0];
            if (wrapper) {
                id t = nil;
                @try { t = [wrapper valueForKey:@"_target"]; } @catch (__unused NSException *e) { }
                if (t) return t;
                if ([wrapper respondsToSelector:FSBHandleTransitionSelector()]) return wrapper;
            }
        }
    } @catch (__unused NSException *e) { }

    @try {
        Class itc = NSClassFromString(@"_UINavigationInteractiveTransition");
        if (itc) {
            for (UIGestureRecognizer *gr in nav.view.gestureRecognizers) {
                id targets = nil;
                @try { targets = [gr valueForKey:@"_targets"]; } @catch (__unused NSException *e) { }
                for (id wrapper in targets) {
                    id t = nil;
                    @try { t = [wrapper valueForKey:@"_target"]; } @catch (__unused NSException *e) { }
                    if (!t) t = wrapper;
                    if ([t isKindOfClass:itc]) return t;
                }
            }
        }
    } @catch (__unused NSException *e) { }

    return nil;
}

static void FSBInstallOnNav(UINavigationController *nav);

static void FSBInstallRetry(UINavigationController *nav, NSInteger attempt) {
    if (attempt > 12) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FSBInstallOnNav(nav);
    });
}

static void FSBInstallOnNav(UINavigationController *nav) {
    if (!nav || ![nav isKindOfClass:[UINavigationController class]]) return;
    if (!FSBEnabled()) return;
    UIView *host = nav.view;
    if (!host) return;
    if (nav.viewControllers.count < 2) return;

    for (UIGestureRecognizer *g in host.gestureRecognizers) {
        if ([g isMemberOfClass:[FSBFullScreenPan class]]) return;   // 已装
    }

    SEL handle = FSBHandleTransitionSelector();
    id target = FSBSystemTransitionTarget(nav);
    if (!target || ![target respondsToSelector:handle]) {
        FSBInstallRetry(nav, 0);     // 系统还没就绪, 稍后重试
        return;
    }

    FSBFullScreenPan *pan = [[FSBFullScreenPan alloc] initWithTarget:target action:handle];
    pan.delegate = [FSBGestureDelegate shared];
    pan.maximumNumberOfTouches = 1;
    pan.minimumNumberOfTouches = 1;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    [pan addTarget:[FSBHaptics shared] action:@selector(trackGesture:)];
    [host addGestureRecognizer:pan];

    NSLog(@"[FullScreenBack] installed on %@ stack=%lu",
          NSStringFromClass([nav class]), (unsigned long)nav.viewControllers.count);
}

static void FSBWalk(UIViewController *vc) {
    if (!vc) return;
    if ([vc isKindOfClass:[UINavigationController class]]) FSBInstallOnNav((UINavigationController *)vc);
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in ((UITabBarController *)vc).viewControllers) FSBWalk(c);
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *c in ((UISplitViewController *)vc).viewControllers) FSBWalk(c);
    }
    for (UIViewController *c in vc.childViewControllers) FSBWalk(c);
    if (vc.presentedViewController) FSBWalk(vc.presentedViewController);
}

static void FSBInstallAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.rootViewController) FSBWalk(w.rootViewController);
                }
            }
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *w in app.windows) if (w.rootViewController) FSBWalk(w.rootViewController);
#pragma clang diagnostic pop
        }
    });
}

// ---------------------------------------------------------------------------
// 5. Hook (runtime 方法替换, 无 Logos)
// ---------------------------------------------------------------------------
// --- UINavigationController / UIViewController 方法替换
typedef struct { Class cls; SEL sel; IMP orig; } FSBSwizzle;

static FSBSwizzle gSwizzle[8];
static int gSwizzleCount = 0;

static FSBSwizzle *FSBSwizzleMethod(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;
    if (gSwizzleCount >= 8) return NULL;
    FSBSwizzle *slot = &gSwizzle[gSwizzleCount++];
    slot->cls = cls;
    slot->sel = sel;
    slot->orig = NULL;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        // 类本身没实现 (纯继承), 直接挂一个新实现, 没有原实现可调
        class_addMethod(cls, sel, newImp, "@@:");
        return slot;
    }
    slot->orig = method_getImplementation(m);
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
    return slot;
}

// 槽位索引 (必须与 FSBEntry 中的注册顺序一致)
#define SW_NAV_VIEWDIDLOAD   0
#define SW_NAV_VIEWDIDAPPEAR 1
#define SW_NAV_PUSH          2
#define SW_NAV_SETVCS        3
#define SW_VC_VIEWDIDAPPEAR  4

static void FSB_UINavigationController_viewDidLoad(id self, SEL _cmd) {
    IMP o = gSwizzle[SW_NAV_VIEWDIDLOAD].orig;
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
    FSBInstallOnNav(self);
}
static void FSB_UINavigationController_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    IMP o = gSwizzle[SW_NAV_VIEWDIDAPPEAR].orig;
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
    FSBInstallOnNav(self);
}
static void FSB_UINavigationController_pushViewController(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    IMP o = gSwizzle[SW_NAV_PUSH].orig;
    if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vc, animated);
    FSBInstallOnNav(self);
}
static void FSB_UINavigationController_setViewControllers(id self, SEL _cmd, NSArray *vcs, BOOL animated) {
    IMP o = gSwizzle[SW_NAV_SETVCS].orig;
    if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vcs, animated);
    FSBInstallOnNav(self);
}
static void FSB_UIViewController_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    IMP o = gSwizzle[SW_VC_VIEWDIDAPPEAR].orig;
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
    UINavigationController *nav = ((UIViewController *)self).navigationController;
    if (nav) FSBInstallOnNav(nav);
}

__attribute__((constructor)) static void FSBEntry(void) {
    @autoreleasepool {
        Class navCls = objc_getClass("UINavigationController");
        Class vcCls  = objc_getClass("UIViewController");
        gSwizzleCount = 0;
        FSBSwizzleMethod(navCls, sel_registerName("viewDidLoad"), (IMP)FSB_UINavigationController_viewDidLoad);
        FSBSwizzleMethod(navCls, sel_registerName("viewDidAppear:"), (IMP)FSB_UINavigationController_viewDidAppear);
        FSBSwizzleMethod(navCls, sel_registerName("pushViewController:animated:"), (IMP)FSB_UINavigationController_pushViewController);
        FSBSwizzleMethod(navCls, sel_registerName("setViewControllers:animated:"), (IMP)FSB_UINavigationController_setViewControllers);
        FSBSwizzleMethod(vcCls, sel_registerName("viewDidAppear:"), (IMP)FSB_UIViewController_viewDidAppear);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ FSBInstallAll(); });

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (NSString *name in @[UIApplicationDidBecomeActiveNotification,
                                 UIApplicationWillEnterForegroundNotification,
                                 UIWindowDidBecomeKeyNotification]) {
            [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) { FSBInstallAll(); }];
        }
        NSLog(@"[FullScreenBack] loaded enabled=%d", (int)FSBEnabled());
    }
}
