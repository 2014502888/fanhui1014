#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

// ============================================================================
//  FullScreenBackTweak 精简核心版
//  只保留核心/稳定性功能：
//    - 绑系统转场 target（跟手返回）
//    - 手势幂等安装 + 单指 + cancelsTouchesInView=NO
//    - 判定：栈≥2 / 转场中不响应 / 模态不响应 / 方向过滤
//    - 全量遍历安装（window→tab→split→child→presented）
//    - @try 防护
//    - pushViewController + UIViewController viewDidAppear 双 hook
//  已剔除：设置项 / 重试 / 左边缘让位 / ScrollView 让位 / 系统边缘手势禁用检查 /
//          通知重装 / 冗余 hook(viewDidLoad/setViewControllers) / 字符串拼接 / 日志
//  震动：恒开、满格 1.0（无设置项）
// ============================================================================

// -------------------- 震动（恒开满格） --------------------
@interface FSBHaptics : NSObject
+ (instancetype)shared;
- (void)trackGesture:(UIPanGestureRecognizer *)g;
@end
@implementation FSBHaptics {
    UIImpactFeedbackGenerator *_gen;
}
+ (instancetype)shared {
    static FSBHaptics *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBHaptics new]; });
    return s;
}
- (void)trackGesture:(UIPanGestureRecognizer *)g {
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [_gen prepare];
            break;
        case UIGestureRecognizerStateEnded: {
            UIView *host = g.view;
            CGFloat w = host ? host.bounds.size.width : 0.0;
            CGFloat tx = [g translationInView:host].x;
            CGFloat vx = [g velocityInView:host].x;
            // 达标：滑过屏宽35% 或 快速右滑
            BOOL passed = (w > 0.0 && tx > w * 0.35) || vx > 300.0;
            if (passed) {
                // 新建即触发，不依赖 Began 时 prepare 的时效（慢滑超时会导致不震）
                // iOS13+ 用强度可调 API；iOS<13 降级系统震动音
                if (@available(iOS 13.0, *)) {
                    UIImpactFeedbackGenerator *g2 =
                        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                    [g2 impactOccurredWithIntensity:1.0];
                } else {
                    AudioServicesPlaySystemSound(1519);
                }
            }
            _gen = nil;
            break;
        }
        default:
            _gen = nil;
            break;
    }
}
@end

// -------------------- 手势（子类标记，幂等判断用） --------------------
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

// -------------------- 手势判定（核心检查） --------------------
@interface FSBGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end
@implementation FSBGestureDelegate
+ (instancetype)shared {
    static FSBGestureDelegate *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FSBGestureDelegate new]; });
    return s;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return NO;

    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)g;
    UINavigationController *nav = FSBNavForView(g.view);
    if (!nav) return NO;
    if (nav.viewControllers.count < 2) return NO;          // 栈底不响应
    if (nav.transitionCoordinator != nil) return NO;       // 转场中不响应
    if (nav.presentedViewController != nil) return NO;     // 模态盖着不响应
    if (nav.isBeingDismissed || nav.isBeingPresented) return NO;

    CGPoint t = [pan translationInView:pan.view];
    if (t.x <= 2.0) return NO;                              // 只认向右
    CGFloat ax = fabs(t.x), ay = fabs(t.y);
    if (ax <= ay) return NO;                                // 必须横向为主
    if (ax > 0.0 && (ay / ax) > 0.98) return NO;            // 不太斜
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
@end

// -------------------- 系统转场 target（跟手的根本） --------------------
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
                if ([wrapper respondsToSelector:NSSelectorFromString(@"handleNavigationTransition:")]) return wrapper;
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

// -------------------- 安装（幂等，target 拿不到则不装） --------------------
static void FSBInstallOnNav(UINavigationController *nav) {
    if (!nav || ![nav isKindOfClass:[UINavigationController class]]) return;
    UIView *host = nav.view;
    if (!host) return;
    if (nav.viewControllers.count < 2) return;

    for (UIGestureRecognizer *g in host.gestureRecognizers) {
        if ([g isMemberOfClass:[FSBFullScreenPan class]]) return;   // 已装
    }

    id target = FSBSystemTransitionTarget(nav);
    if (!target || ![target respondsToSelector:NSSelectorFromString(@"handleNavigationTransition:")]) return;

    FSBFullScreenPan *pan = [[FSBFullScreenPan alloc] initWithTarget:target
                                                              action:NSSelectorFromString(@"handleNavigationTransition:")];
    pan.delegate = [FSBGestureDelegate shared];
    pan.maximumNumberOfTouches = 1;
    pan.minimumNumberOfTouches = 1;
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    [pan addTarget:[FSBHaptics shared] action:@selector(trackGesture:)];
    [host addGestureRecognizer:pan];
}

// -------------------- 全量遍历安装 --------------------
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

// -------------------- Hook（runtime swizzle，无 Logos） --------------------
typedef struct { IMP orig; } FSBSwizzle;

static FSBSwizzle gSwizzle[2];
static int gSwizzleCount = 0;

static FSBSwizzle *FSBSwizzleMethod(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;
    if (gSwizzleCount >= 2) return NULL;
    FSBSwizzle *slot = &gSwizzle[gSwizzleCount++];
    slot->orig = NULL;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        class_addMethod(cls, sel, newImp, "@@:");
        return slot;
    }
    slot->orig = method_getImplementation(m);
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
    return slot;
}

#define SW_NAV_PUSH          0
#define SW_VC_VIEWDIDAPPEAR  1

static void FSB_UINavigationController_pushViewController(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    IMP o = gSwizzle[SW_NAV_PUSH].orig;
    if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vc, animated);
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
        FSBSwizzleMethod(navCls, sel_registerName("pushViewController:animated:"), (IMP)FSB_UINavigationController_pushViewController);
        FSBSwizzleMethod(vcCls, sel_registerName("viewDidAppear:"), (IMP)FSB_UIViewController_viewDidAppear);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ FSBInstallAll(); });
    }
}
