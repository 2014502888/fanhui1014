#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
// ==================== 常量（无设置项：总开、震动默认开、力度1.0满格） ====================
#define FBS_STRENGTH 1.0
static void FBSInstallOnNav(UINavigationController *nav); // 前置声明（verify兜底里会调用）
// ==================== 全屏手势 ====================
@interface FBSPanGesture : UIPanGestureRecognizer
@end
@implementation FBSPanGesture
@end
// ==================== 震动 ====================
@interface FBSHaptic : NSObject
+ (instancetype)shared;
- (void)track:(UIPanGestureRecognizer *)g;
@end
@implementation FBSHaptic
{
    UIImpactFeedbackGenerator *_gen;
}
+ (instancetype)shared {
    static FBSHaptic *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FBSHaptic new]; });
    return s;
}
- (void)track:(UIPanGestureRecognizer *)g {
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            _gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [_gen prepare];
            break;
        case UIGestureRecognizerStateEnded: {
            CGFloat tx = [g translationInView:g.view].x;
            CGFloat vx = [g velocityInView:g.view].x;
            if (tx > w * 0.35 || vx > 300) {
                [_gen impactOccurredWithIntensity:FBS_STRENGTH];
            }
            _gen = nil;
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            _gen = nil;
            break;
        default: break;
    }
}
@end
// ==================== 手势delegate ====================
@interface FBSDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)verify:(UIPanGestureRecognizer *)g;
- (void)selfPop:(UIPanGestureRecognizer *)g;
@end
@implementation FBSDelegate
+ (instancetype)shared {
    static FBSDelegate *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FBSDelegate new]; });
    return s;
}
- (UINavigationController *)navOf:(UIView *)v {
    UIResponder *r = v.nextResponder;
    while (r) {
        if ([r isKindOfClass:[UINavigationController class]]) return (id)r;
        if ([r isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (id)r;
            if (vc.navigationController) return vc.navigationController;
        }
        r = r.nextResponder;
    }
    return nil;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
    UIPanGestureRecognizer *p = (id)g;
    UINavigationController *nav = [self navOf:g.view];
    if (!nav || nav.viewControllers.count < 2) return NO;
    CGPoint t = [p translationInView:g.view];
    if (t.x < 2) return NO;
    if (fabs(t.x) < fabs(t.y)) return NO;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}
// 兜底验证：达标滑动结束后，若系统转场没执行（栈深没变），手动pop返回，不用等系统恢复
- (void)verify:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat tx = [g translationInView:g.view].x;
    CGFloat vx = [g velocityInView:g.view].x;
    if (tx < w * 0.35 && vx <= 300) return; // 没达标不兜底
    UINavigationController *nav = [self navOf:g.view];
    if (!nav || nav.viewControllers.count < 2) return;
    NSUInteger before = nav.viewControllers.count;
    __weak UINavigationController *wnav = nav;
    // 等1.2s：覆盖系统转场驱动器延迟响应的窗口，避免兜底pop与系统补刀造成双pop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UINavigationController *nav2 = wnav;
        if (!nav2 || !nav2.view.window) return; // 界面已不在
        if (nav2.transitionCoordinator) return; // 系统转场动画进行中，交给系统完成
        if (nav2.viewControllers.count == before && nav2.viewControllers.count > 1) {
            // 隔离系统边缘手势，防止它补刀造成双pop；pop后恢复并重装手势对齐target
            UIGestureRecognizer *sysPop = nav2.interactivePopGestureRecognizer;
            BOOL wasEnabled = sysPop.enabled;
            sysPop.enabled = NO;
            [nav2 popViewControllerAnimated:YES];
            __weak UINavigationController *wnav3 = nav2;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UINavigationController *nv = wnav3;
                if (!nv) return;
                nv.interactivePopGestureRecognizer.enabled = wasEnabled;
                FBSInstallOnNav(nv);
            });
        }
    });
}
// 自实现返回：系统转场驱动器拿不到时的兜底（资料页等特殊页面，非跟手，达标直接pop）
- (void)selfPop:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat tx = [g translationInView:g.view].x;
    CGFloat vx = [g velocityInView:g.view].x;
    if (tx < w * 0.35 && vx <= 300) return;
    UINavigationController *nav = [self navOf:g.view];
    if (!nav || nav.viewControllers.count < 2) return;
    [nav popViewControllerAnimated:YES];
}
@end
// ==================== 安装手势 ====================
static SEL FBSHandleTransitionSEL(void) {
    static SEL s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = NSSelectorFromString(@"handleNavigationTransition:"); });
    return s;
}
// 取手势当前的转场驱动器target（_targets 首个 wrapper 的 _target）
static id FBSTargetOf(UIGestureRecognizer *g) {
    NSArray *targets = [g valueForKey:@"_targets"];
    id wrapper = targets.firstObject;
    return [wrapper valueForKey:@"_target"];
}
// 三级取系统交互式转场驱动器（WCPulse 首选 _cachedInteractionController，回退 _targets，再回退类扫描）
static id FSBTransitionTarget(UINavigationController *nav) {
    SEL handle = FBSHandleTransitionSEL();
    // 路径A：nav 私有 _cachedInteractionController（WCPulse 实际用的，资料页也能拿到）
    @try {
        SEL cached = NSSelectorFromString(@"_cachedInteractionController");
        if ([nav respondsToSelector:cached]) {
            id ic = ((id (*)(id, SEL))objc_msgSend)(nav, cached);
            if (ic && [ic respondsToSelector:handle]) return ic;
        }
    } @catch (NSException *e) {}
    // 路径B：系统交互式pop手势的 _targets[0]._target
    @try {
        UIGestureRecognizer *sys = nav.interactivePopGestureRecognizer;
        if (sys) {
            id targets = [sys valueForKey:@"_targets"];
            if ([targets isKindOfClass:[NSArray class]] && [targets count] > 0) {
                id wrapper = [targets objectAtIndex:0];
                id t = [wrapper valueForKey:@"_target"];
                if (t && [t respondsToSelector:handle]) return t;
                if (wrapper && [wrapper respondsToSelector:handle]) return wrapper;
            }
        }
    } @catch (NSException *e) {}
    // 路径C：nav.view 手势里扫描 _UINavigationInteractiveTransition 实例
    @try {
        Class itc = NSClassFromString(@"_UINavigationInteractiveTransition");
        if (itc) {
            for (UIGestureRecognizer *gr in nav.view.gestureRecognizers) {
                id targets = [gr valueForKey:@"_targets"];
                if (![targets isKindOfClass:[NSArray class]]) continue;
                for (id wrapper in targets) {
                    id t = [wrapper valueForKey:@"_target"];
                    if (!t) t = wrapper;
                    if ([t isKindOfClass:itc] && [t respondsToSelector:handle]) return t;
                }
            }
        }
    } @catch (NSException *e) {}
    return nil;
}
static void FBSInstallOnNav(UINavigationController *nav) {
    @try {
        // 找已装手势
        FBSPanGesture *existing = nil;
        for (UIGestureRecognizer *g in nav.view.gestureRecognizers) {
            if ([g isMemberOfClass:[FBSPanGesture class]]) { existing = (id)g; break; }
        }
        
        // 三级取系统当前最新的转场驱动器target
        id target = FSBTransitionTarget(nav);
        if (!target) {
            // 三级都拿不到（特殊页面）：已有可用手势就保留，否则装自实现返回（非跟手但能用）
            if (existing) return;
            FBSPanGesture *gesture = [[FBSPanGesture alloc] initWithTarget:[FBSDelegate shared]
                                                                   action:@selector(selfPop:)];
            gesture.delegate = [FBSDelegate shared];
            gesture.maximumNumberOfTouches = 1;
            [gesture addTarget:[FBSHaptic shared] action:@selector(track:)];
            [gesture addTarget:[FBSDelegate shared] action:@selector(verify:)];
            [nav.view addGestureRecognizer:gesture];
            return;
        }
        
        // 幂等：已装手势且 target 没变就不动（频繁删改手势会打断UIKit触摸分发导致卡死）
        if (existing) {
            if (FBSTargetOf(existing) == target) return;
            [nav.view removeGestureRecognizer:existing];
        }
        
        FBSPanGesture *gesture = [[FBSPanGesture alloc] initWithTarget:target
                                                               action:NSSelectorFromString(@"handleNavigationTransition:")];
        gesture.delegate = [FBSDelegate shared];
        gesture.maximumNumberOfTouches = 1;
        [gesture addTarget:[FBSHaptic shared] action:@selector(track:)];
        [gesture addTarget:[FBSDelegate shared] action:@selector(verify:)];
        [nav.view addGestureRecognizer:gesture];
    } @catch (NSException *e) {}
}
// ==================== Hook _layoutTopViewController（WCPulse的安装时机：每次导航栏布局必调，天然幂等懒加载） ====================
static void FBSHookLayoutTopForClass(Class cls) {
    SEL sel = NSSelectorFromString(@"_layoutTopViewController");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return; // 私有方法不存在（系统改名）就跳过，不添加空实现
    __block IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self) {
        ((void (*)(id, SEL))orig)(self, sel);
        FBSInstallOnNav((id)self);
    }));
}
// ==================== Hook指定类的push方法 ====================
static void FBSHookPushForClass(Class cls) {
    Method m = class_getInstanceMethod(cls, @selector(pushViewController:animated:));
    if (m) {
        __block IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, UIViewController *vc, BOOL animated) {
            ((void(*)(id, SEL, id, BOOL))orig)(self, @selector(pushViewController:animated:), vc, animated);
            FBSInstallOnNav((id)self);
        }));
    }
}
// ==================== Hook setViewControllers（微信换栈路径，如"好友资料→发消息"） ====================
static void FBSHookSetVCForClass(Class cls) {
    Method m = class_getInstanceMethod(cls, @selector(setViewControllers:animated:));
    if (m) {
        __block IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, NSArray *vcs, BOOL animated) {
            ((void(*)(id, SEL, NSArray*, BOOL))orig)(self, @selector(setViewControllers:animated:), vcs, animated);
            FBSInstallOnNav((id)self);
        }));
    }
}
// ==================== Hook popToViewController（微信回栈路径） ====================
static void FBSHookPopToForClass(Class cls) {
    Method m = class_getInstanceMethod(cls, @selector(popToViewController:animated:));
    if (m) {
        __block IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, UIViewController *vc, BOOL animated) {
            ((void(*)(id, SEL, id, BOOL))orig)(self, @selector(popToViewController:animated:), vc, animated);
            FBSInstallOnNav((id)self);
        }));
    }
}
// ==================== Hook UINavigationController viewDidAppear（资料页所在nav一旦出现确保装上，幂等不删改） ====================
static void FBSHookNavViewDidAppear(Class navCls) {
    Method m = class_getInstanceMethod(navCls, @selector(viewDidAppear:));
    if (m) {
        __block IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, BOOL animated) {
            ((void(*)(id, SEL, BOOL))orig)(self, @selector(viewDidAppear:), animated);
            FBSInstallOnNav((id)self);
        }));
    }
}
// ==================== Hook viewDidAppear ====================
static void FBSHookViewDidAppear(void) {
    Class vcCls = [UIViewController class];
    Method m = class_getInstanceMethod(vcCls, @selector(viewDidAppear:));
    if (m) {
        __block IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, BOOL animated) {
            ((void(*)(id, SEL, BOOL))orig)(self, @selector(viewDidAppear:), animated);
            @try {
                UIViewController *vc = (id)self;
                if (vc.navigationController) {
                    FBSInstallOnNav(vc.navigationController);
                }
            } @catch (__unused NSException *e) {}
        }));
    }
}
static BOOL gFBSHooked = NO; // hook 只注册一次，防止 didBecomeActive 反复调用导致嵌套
static void FBSInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gFBSHooked) {
            gFBSHooked = YES;
            // hook标准UINavigationController
            FBSHookLayoutTopForClass([UINavigationController class]);
            FBSHookPushForClass([UINavigationController class]);
            FBSHookSetVCForClass([UINavigationController class]);
            FBSHookPopToForClass([UINavigationController class]);
            FBSHookNavViewDidAppear([UINavigationController class]);
            // hook微信自定义的MMUINavigationController
            Class mmNavCls = NSClassFromString(@"MMUINavigationController");
            if (mmNavCls) {
                FBSHookLayoutTopForClass(mmNavCls);
                FBSHookPushForClass(mmNavCls);
                FBSHookSetVCForClass(mmNavCls);
                FBSHookPopToForClass(mmNavCls);
                FBSHookNavViewDidAppear(mmNavCls);
            }
            FBSHookViewDidAppear();
        }
        
        // 遍历所有window装手势
        for (UIWindowScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in s.windows) {
                if (w.rootViewController) {
                    NSMutableArray *queue = [NSMutableArray array];
                    [queue addObject:w.rootViewController];
                    NSUInteger qi = 0;
                    while (qi < queue.count) {
                        UIViewController *vc = [queue objectAtIndex:qi];
                        qi++;
                        if ([vc isKindOfClass:[UINavigationController class]]) {
                            FBSInstallOnNav((id)vc);
                        }
                        for (UIViewController *c in vc.childViewControllers) {
                            [queue addObject:c];
                        }
                    }
                }
            }
        }
    });
}
__attribute__((constructor)) static void WXConstructor(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ FBSInstall(); });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n){ FBSInstall(); }];
}
