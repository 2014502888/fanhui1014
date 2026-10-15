// ============================================================================
//  FullScreenBackTweak.m — 全屏返回（方案A：非交互式 pop，根治多次滑动卡界面）
// ============================================================================
//  路线：手势只做「识别 + 震动 + 达标判定」，Ended 达标时直接
//        [nav popViewControllerAnimated:YES]（非交互式标准转场）。
//  完全不调用系统私有 handleNavigationTransition: —— 不存在可被污染的
//  交互式转场状态机，多次滑动/连滑/主界面反复触发都不可能卡界面。
//  代价：滑动不跟手（松手后才执行 pop 动画）。
//  保留：栈底不装手势 / 模态与转场忙检查 / 左边缘让位系统手势 /
//        横滚 ScrollView 让位 / cancelsTouchesInView=NO / 全 @try 防护。
// ============================================================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

// ------------------------------ 1. 写死常量 ---------------------------------
static const CGFloat kFSBDistance = 0.30f;    // 松手判定：拖过屏幕宽度 30% 才返回
static const CGFloat kFSBLeftZone = 22.0f;    // 左边缘让位宽度(pt)，让给系统原生边缘手势
static const CGFloat kFSBStrength = 0.8f;     // 确认震动力度 0~1
static const CGFloat kFSBFastVel  = 320.0f;   // 快速滑动速度阈值 (pt/s)
static const CGFloat kFSBFastMinX = 8.0f;     // 快速滑动最小位移 (pt)
// 震动默认开（无开关、无设置项）

// ------------------------------ 2. 触觉反馈 ---------------------------------
@interface FSBHaptics : NSObject
+ (instancetype)shared;
- (void)trackGesture:(UIPanGestureRecognizer *)g;
@end

@implementation FSBHaptics {
    UIImpactFeedbackGenerator    *_heavy;
    UISelectionFeedbackGenerator *_light;
    BOOL _crossed;
}
+ (instancetype)shared {
    static FSBHaptics *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBHaptics new]; });
    return s;
}
- (void)trackGesture:(UIPanGestureRecognizer *)g {
    @try {
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
                if (x >= w * kFSBDistance) {
                    if (!_crossed) { _crossed = YES; [_light selectionChanged]; }
                } else {
                    _crossed = NO;
                }
                break;
            }
            case UIGestureRecognizerStateEnded: {
                UIView *host = g.view;
                CGFloat w = host ? host.bounds.size.width : 0.0;
                CGPoint tr  = [g translationInView:host];
                CGPoint vel = [g velocityInView:host];
                BOOL passed = (w > 0.0 && tr.x > w * kFSBDistance) ||
                              (vel.x > kFSBFastVel && tr.x > kFSBFastMinX);
                if (passed) {
                    UIImpactFeedbackGenerator *gen =
                        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                    [gen impactOccurredWithIntensity:kFSBStrength];
                }
                _heavy = nil; _light = nil; _crossed = NO;
                break;
            }
            default:
                _heavy = nil; _light = nil; _crossed = NO;
                break;
        }
    } @catch (id e) {}
}
@end

// ------------------------------ 3. 手势子类 ---------------------------------
@interface FSBFullScreenPan : UIPanGestureRecognizer
@end
@implementation FSBFullScreenPan
@end

// ------------------------------ 4. 工具函数 ---------------------------------
static UINavigationController *FSBNavForView(UIView *v) {
    @try {
        UIResponder *r = v;
        while (r) {
            if ([r isKindOfClass:[UINavigationController class]]) return (UINavigationController *)r;
            if ([r isKindOfClass:[UIViewController class]]) {
                UIViewController *vc = (UIViewController *)r;
                if (vc.navigationController) return vc.navigationController;
            }
            r = r.nextResponder;
        }
    } @catch (id e) {}
    return nil;
}

// 转场进行中 / 上面盖着模态 / 正在被 present/dismiss → 不触发
static BOOL FSBNavBusy(UINavigationController *nav) {
    @try {
        if (!nav) return YES;
        if (nav.transitionCoordinator != nil) return YES;
        if (nav.presentedViewController != nil) return YES;
        if (nav.isBeingDismissed || nav.isBeingPresented) return YES;
    } @catch (id e) {}
    return NO;
}

// ------------------------------ 5. 手势处理（方案A核心） ---------------------
// 单例 target：static 强持有，addTarget 弱引用不会野指针
@interface FSBHandler : NSObject
+ (instancetype)shared;
- (void)handleGesture:(UIPanGestureRecognizer *)g;
@end

@implementation FSBHandler
+ (instancetype)shared {
    static FSBHandler *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBHandler new]; });
    return s;
}
- (void)handleGesture:(UIPanGestureRecognizer *)g {
    @try {
        if (g.state != UIGestureRecognizerStateEnded) return;
        UINavigationController *nav = FSBNavForView(g.view);
        if (!nav || nav.viewControllers.count < 2) return;
        if (FSBNavBusy(nav)) return;

        UIView *host = g.view;
        CGFloat w = host ? host.bounds.size.width : 0.0;
        CGPoint tr  = [g translationInView:host];
        CGPoint vel = [g velocityInView:host];
        BOOL passed = (w > 0.0 && tr.x > w * kFSBDistance) ||
                      (vel.x > kFSBFastVel && tr.x > kFSBFastMinX);
        if (!passed) return;

        // 非交互式 pop：UIKit 标准转场，无交互状态机可污染
        [nav popViewControllerAnimated:YES];
    } @catch (id e) {}
}
@end

// ------------------------------ 6. 手势代理 ---------------------------------
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
    @try {
        if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)g;
        UINavigationController *nav = FSBNavForView(g.view);
        if (!nav || nav.viewControllers.count < 2) return NO;
        if (FSBNavBusy(nav)) return NO;

        CGPoint t = [pan translationInView:g.view];
        if (t.x <= 2.0) return NO;                    // 必须向右
        CGFloat ax = fabs(t.x), ay = fabs(t.y);
        if (ax <= ay) return NO;                      // 必须比纵向更横向
        if (ay / ax > 0.98) return NO;                // 太斜不算

        // 左边缘让位给系统原生边缘手势（它更早、更跟手，用户从边缘滑仍有跟手体验）
        if ([pan locationInView:g.view].x <= kFSBLeftZone) return NO;
        return YES;
    } @catch (id e) { return NO; }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}
// 落在「真能横向滚动的 UIScrollView」上时不抢手势
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    @try {
        UIView *v = touch.view;
        UIView *root = g.view;
        while (v && v != root) {
            if ([v isKindOfClass:[UIScrollView class]]) {
                UIScrollView *sv = (UIScrollView *)v;
                if (sv.contentSize.width > sv.bounds.size.width + 8.0) return NO;
            }
            v = v.superview;
        }
    } @catch (id e) {}
    return YES;
}
@end

// ------------------------------ 7. 安装 -------------------------------------
static void FSBInstallOnNav(UINavigationController *nav) {
    @try {
        if (!nav || ![nav isKindOfClass:[UINavigationController class]]) return;
        UIView *host = nav.view;
        if (!host) return;
        if (nav.viewControllers.count < 2) return;   // 栈底不装，物理杜绝栈底触发

        // 幂等：已经装过直接返回
        for (UIGestureRecognizer *g in host.gestureRecognizers) {
            if ([g isMemberOfClass:[FSBFullScreenPan class]]) return;
        }

        FSBFullScreenPan *pan = [[FSBFullScreenPan alloc] initWithTarget:[FSBHandler shared]
                                                                   action:@selector(handleGesture:)];
        pan.delegate = [FSBGestureDelegate shared];
        pan.maximumNumberOfTouches = 1;
        pan.cancelsTouchesInView = NO;   // 手势激活也不吞触摸
        pan.delaysTouchesBegan = NO;

        [pan addTarget:[FSBHaptics shared] action:@selector(trackGesture:)];
        [host addGestureRecognizer:pan];
        NSLog(@"[FullScreenBack] installed(A) on %@ stack=%lu",
              NSStringFromClass([nav class]), (unsigned long)nav.viewControllers.count);
    } @catch (id e) {}
}

// 递归遍历：nav / tab / split / child / presented
static void FSBWalk(UIViewController *vc) {
    if (!vc) return;
    @try {
        if ([vc isKindOfClass:[UINavigationController class]]) {
            FSBInstallOnNav((UINavigationController *)vc);
            for (UIViewController *c in ((UINavigationController *)vc).viewControllers) FSBWalk(c);
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            for (UIViewController *c in ((UITabBarController *)vc).viewControllers) FSBWalk(c);
        }
        if ([vc isKindOfClass:[UISplitViewController class]]) {
            for (UIViewController *c in ((UISplitViewController *)vc).viewControllers) FSBWalk(c);
        }
        for (UIViewController *c in vc.childViewControllers) FSBWalk(c);
        if (vc.presentedViewController) FSBWalk(vc.presentedViewController);
    } @catch (id e) {}
}

static void FSBInstallAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.rootViewController) FSBWalk(w.rootViewController);
                }
            }
        } @catch (id e) {}
    });
}

// ------------------------------ 8. Hook -------------------------------------
typedef struct { Class cls; SEL sel; IMP orig; } FSBSwizzle;

static FSBSwizzle gSwizzle[8];
static int gSwizzleCount = 0;

static void FSBSwizzleMethod(Class cls, SEL sel, IMP newImp) {
    @try {
        if (!cls || !sel || !newImp || gSwizzleCount >= 8) return;
        FSBSwizzle *slot = &gSwizzle[gSwizzleCount++];
        slot->cls = cls;
        slot->sel = sel;
        slot->orig = NULL;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            class_addMethod(cls, sel, newImp, "@@:");
            return;
        }
        slot->orig = method_getImplementation(m);
        class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
    } @catch (id e) {}
}

#define SW_NAV_VIEWDIDLOAD   0
#define SW_NAV_VIEWDIDAPPEAR 1
#define SW_NAV_PUSH          2
#define SW_NAV_SETVCS        3
#define SW_VC_VIEWDIDAPPEAR  4

static void FSB_UINavigationController_viewDidLoad(id self, SEL _cmd) {
    @try {
        IMP o = gSwizzle[SW_NAV_VIEWDIDLOAD].orig;
        if (o) ((void (*)(id, SEL))o)(self, _cmd);
    } @catch (id e) {}
    FSBInstallOnNav(self);
}
static void FSB_UINavigationController_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    @try {
        IMP o = gSwizzle[SW_NAV_VIEWDIDAPPEAR].orig;
        if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
    } @catch (id e) {}
    if (((UINavigationController *)self).viewControllers.count >= 2) FSBInstallOnNav(self);
}
static void FSB_UINavigationController_pushViewController(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    @try {
        IMP o = gSwizzle[SW_NAV_PUSH].orig;
        if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vc, animated);
    } @catch (id e) {}
    dispatch_async(dispatch_get_main_queue(), ^{ FSBInstallOnNav(self); });
}
static void FSB_UINavigationController_setViewControllers(id self, SEL _cmd, NSArray *vcs, BOOL animated) {
    @try {
        IMP o = gSwizzle[SW_NAV_SETVCS].orig;
        if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vcs, animated);
    } @catch (id e) {}
    dispatch_async(dispatch_get_main_queue(), ^{ FSBInstallOnNav(self); });
}
static void FSB_UIViewController_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    @try {
        IMP o = gSwizzle[SW_VC_VIEWDIDAPPEAR].orig;
        if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
    } @catch (id e) {}
    @try {
        UINavigationController *nav = ((UIViewController *)self).navigationController;
        if (nav) FSBInstallOnNav(nav);
    } @catch (id e) {}
}

// ------------------------------ 9. 入口 -------------------------------------
__attribute__((constructor)) static void FSBEntry(void) {
    @autoreleasepool {
        @try {
            Class navCls = objc_getClass("UINavigationController");
            Class vcCls  = objc_getClass("UIViewController");
            gSwizzleCount = 0;
            FSBSwizzleMethod(navCls, sel_registerName("viewDidLoad"),
                             (IMP)FSB_UINavigationController_viewDidLoad);
            FSBSwizzleMethod(navCls, sel_registerName("viewDidAppear:"),
                             (IMP)FSB_UINavigationController_viewDidAppear);
            FSBSwizzleMethod(navCls, sel_registerName("pushViewController:animated:"),
                             (IMP)FSB_UINavigationController_pushViewController);
            FSBSwizzleMethod(navCls, sel_registerName("setViewControllers:animated:"),
                             (IMP)FSB_UINavigationController_setViewControllers);
            FSBSwizzleMethod(vcCls, sel_registerName("viewDidAppear:"),
                             (IMP)FSB_UIViewController_viewDidAppear);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ FSBInstallAll(); });

            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            for (NSString *name in @[UIApplicationDidBecomeActiveNotification,
                                     UIApplicationWillEnterForegroundNotification,
                                     UIWindowDidBecomeKeyNotification]) {
                [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *n) { FSBInstallAll(); }];
            }
            NSLog(@"[FullScreenBack] loaded (planA non-interactive)");
        } @catch (id e) {}
    }
}
