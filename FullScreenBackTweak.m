#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
// ==================== 设置存储 ====================
static NSString *kFBSKeyEnabled = @"fbs_enabled";
static NSString *kFBSKeyHaptic  = @"fbs_haptic";
static NSString *kFBSKeyStrength = @"fbs_strength";
static BOOL FBSGetEnabled(void)   { return [[NSUserDefaults standardUserDefaults] boolForKey:kFBSKeyEnabled] ?: YES; }
static BOOL FBSGetHaptic(void)    { return [[NSUserDefaults standardUserDefaults] boolForKey:kFBSKeyHaptic] ?: YES; }
static double FBSGetStrength(void){ return [[NSUserDefaults standardUserDefaults] doubleForKey:kFBSKeyStrength] ?: 0.8; }
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
    if (!FBSGetHaptic()) return;
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
                double s = FBSGetStrength();
                if (s < 0.01) s = 0.01;
                if (s > 1.0) s = 1.0;
                [_gen impactOccurredWithIntensity:s];
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
static BOOL FBSBusy = NO; // 全局转场锁：一次 pop 转场未结束前禁止新手势

static UINavigationController *FBSNavOf(UIView *v) {
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

@interface FBSDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end
@implementation FBSDelegate
+ (instancetype)shared {
    static FBSDelegate *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FBSDelegate new]; });
    return s;
}
- (UINavigationController *)navOf:(UIView *)v {
    return FBSNavOf(v);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (!FBSGetEnabled()) return NO;
    if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
    UIPanGestureRecognizer *p = (id)g;
    UINavigationController *nav = FBSNavOf(g.view);
    if (!nav || nav.viewControllers.count < 2) return NO;
    // 系统边缘返回手势被禁用（导航栈无可 pop 页面时 UIKit 自动禁用 interactivePopGestureRecognizer）
    // 此时全屏手势也不应开始：否则手势 Ended 仍会向系统过渡 handleNavigationTransition: 发消息，
    // 空栈 pop 导致 UIKit 动画状态错乱 -> 主线程卡死
    if (!nav.interactivePopGestureRecognizer.enabled) return NO;
    // 全局转场锁：上一次 pop 转场尚未结束（含动画播放期），禁止新手势
    if (FBSBusy) return NO;
    // 私有状态：UIKit 导航过渡/转场进行中（比 transitionCoordinator 更早成立）
    @try {
        id tr = [nav valueForKey:@"_isTransitioning"];
        if (tr && [tr boolValue]) return NO;
    } @catch (__unused NSException *e) {}
    // nav.view 上仍有 CAAnimation（push/pop 转场动画播放中）也不应开始
    if (nav.view.layer.animationKeys.count > 0) return NO;
    if (nav.transitionCoordinator && nav.transitionCoordinator.isAnimated) return NO;
    CGPoint t = [p translationInView:g.view];
    if (t.x < 2) return NO;
    if (fabs(t.x) < fabs(t.y)) return NO;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return NO;
}
@end
// ==================== 手势状态守卫 ====================
// 在识别器整个生命周期做二次校验 + 设置/清除全局转场锁，
// 防止交互式 pop 转场进行中第二个手势再次驱动系统转场（双驱动 -> 状态机错乱 -> UI 卡死）
@interface FBSGuard : NSObject
+ (instancetype)shared;
- (void)track:(UIPanGestureRecognizer *)g;
@end
@implementation FBSGuard
+ (instancetype)shared {
    static FBSGuard *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FBSGuard new]; });
    return s;
}
- (void)track:(UIPanGestureRecognizer *)g {
    UINavigationController *nav = FBSNavOf(g.view);
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            // 二次校验：识别器已激活，若此刻栈底/转场进行中，强制重置（触摸取消，不驱动系统转场）
            if (!nav || nav.viewControllers.count < 2) { g.enabled = NO; g.enabled = YES; return; }
            @try {
                id tr = [nav valueForKey:@"_isTransitioning"];
                if (tr && [tr boolValue]) { g.enabled = NO; g.enabled = YES; return; }
            } @catch (__unused NSException *e) {}
            if (nav.view.layer.animationKeys.count > 0) { g.enabled = NO; g.enabled = YES; return; }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            // 手势结束（可能 commit 了 pop 也可能取消），进入转场动画期：上锁
            FBSBusy = YES;
            id<UIViewControllerTransitionCoordinator> c = nav ? nav.transitionCoordinator : nil;
            if (c) {
                [c animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
                    FBSBusy = NO;
                }];
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    FBSBusy = NO;
                });
            }
            // 兜底：无论 completion 是否回调，1.5s 后强制解锁，防止锁泄漏导致全屏返回永久失效
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FBSBusy = NO;
            });
            break;
        }
        default: break;
    }
}
@end
// ==================== 安装手势 ====================
static void FBSInstallOnNav(UINavigationController *nav) {
    @try {
        // 检查有没有装过
        for (UIGestureRecognizer *g in nav.view.gestureRecognizers) {
            if ([g isMemberOfClass:[FBSPanGesture class]]) return;
        }
        
        // 方式1: 从interactivePopGestureRecognizer拿target
        UIGestureRecognizer *sys = nav.interactivePopGestureRecognizer;
        NSArray *targets = [sys valueForKey:@"_targets"];
        id wrapper = targets.firstObject;
        id target = [wrapper valueForKey:@"_target"];
        
        if (target) {
            // 用系统的target
            FBSPanGesture *gesture = [[FBSPanGesture alloc] initWithTarget:target
                                                                   action:NSSelectorFromString(@"handleNavigationTransition:")];
            gesture.delegate = [FBSDelegate shared];
            gesture.maximumNumberOfTouches = 1;
            [gesture addTarget:[FBSHaptic shared] action:@selector(track:)];
            [gesture addTarget:[FBSGuard shared] action:@selector(track:)];
            // 关键：全屏手势等待系统边缘手势失败后才识别。
            // 左边缘滑动由系统手势驱动（避免两个手势同时驱动同一转场导致状态错乱）；
            // 非边缘（20pt 外）系统手势立即失败 -> 全屏手势接管。
            if (sys) [gesture requireGestureRecognizerToFail:sys];
            [nav.view addGestureRecognizer:gesture];
        } else {
            // 方式2: 拿不到target,用自己的处理
            FBSPanGesture *gesture = [[FBSPanGesture alloc] init];
            gesture.delegate = [FBSDelegate shared];
            gesture.maximumNumberOfTouches = 1;
            [gesture addTarget:[FBSHaptic shared] action:@selector(track:)];
            [gesture addTarget:[FBSGuard shared] action:@selector(track:)];
            [nav.view addGestureRecognizer:gesture];
        }
    } @catch (NSException *e) {}
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
static void FBSInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // hook标准UINavigationController
        FBSHookPushForClass([UINavigationController class]);
        // hook微信自定义的MMUINavigationController
        Class mmNavCls = NSClassFromString(@"MMUINavigationController");
        if (mmNavCls) {
            FBSHookPushForClass(mmNavCls);
        }
        FBSHookViewDidAppear();
        
        // 遍历所有window装手势
        for (UIWindowScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in s.windows) {
                if (w.rootViewController) {
                    NSMutableArray *queue = [NSMutableArray arrayWithObject:w.rootViewController];
                    while (queue.count > 0) {
                        UIViewController *vc = queue.firstObject;
                        [queue removeObjectAtIndex:0];
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
