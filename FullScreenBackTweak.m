#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <math.h>
#include <stdarg.h>
// ==================== 常量（无设置项：总开、震动默认开、力度1.0满格） ====================
#define FBS_STRENGTH 1.0
static void FBSInstallOnNav(UINavigationController *nav); // 前置声明（verify兜底里会调用）
static SEL FBSHandleTransitionSEL(void); // 前置声明（drive:里会调用）
// ==================== 诊断日志（Console可见 + 写微信Documents/fbs_debug.log，可用3uTools导出） ====================
static void FBSLog(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSLog(@"[FullScreenBack] %@", msg);
        NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                          stringByAppendingPathComponent:@"fbs_debug.log"];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}
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
- (void)drive:(UIPanGestureRecognizer *)g;
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
    if (!nav) { FBSLog(@"shouldBegin REJECT: no nav"); return NO; }
    if (nav.viewControllers.count < 2) { FBSLog(@"shouldBegin REJECT: stack=%lu", (unsigned long)nav.viewControllers.count); return NO; }
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
            FBSLog(@"verify FALLBACK pop nav=%@ stack=%lu", nav2, (unsigned long)before);
            // 先移除我们自己的手势（系统转场驱动器不再被驱动），再禁系统边缘手势，杜绝任何延迟补刀造成双pop
            for (UIGestureRecognizer *g in [nav2.view.gestureRecognizers copy]) {
                if ([g isMemberOfClass:[FBSPanGesture class]]) [nav2.view removeGestureRecognizer:g];
            }
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
// 动态驱动：每次手势状态变化现取导航最新的系统转场驱动器转发handleNavigationTransition:
// 根治target过期（资料页等页面push后驱动器更新，静态绑定的旧target不响应，系统边缘手势却总是最新的）
- (void)drive:(UIPanGestureRecognizer *)g {
    UINavigationController *nav = [self navOf:g.view];
    if (!nav) return;
    SEL handle = FBSHandleTransitionSEL();
    // 现取系统边缘手势的最新转场驱动器（资料页上它一定有效）
    id target = nil;
    @try {
        UIGestureRecognizer *sys = nav.interactivePopGestureRecognizer;
        id targets = [sys valueForKey:@"_targets"];
        if ([targets isKindOfClass:[NSArray class]] && [targets count] > 0) {
            id wrapper = [targets objectAtIndex:0];
            target = [wrapper valueForKey:@"_target"];
            if (![target respondsToSelector:handle]) target = nil;
        }
    } @catch (NSException *e) {}
    if (target) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, handle, g);
    } else if (g.state == UIGestureRecognizerStateEnded) {
        // 最新驱动器也拿不到：达标直接自实现pop（非跟手但能用）
        CGFloat w = [UIScreen mainScreen].bounds.size.width;
        CGFloat tx = [g translationInView:g.view].x;
        CGFloat vx = [g velocityInView:g.view].x;
        if ((tx > w * 0.35 || vx > 300) && nav.viewControllers.count > 1) {
            FBSLog(@"SELFPOP nav=%@ stack=%lu", nav, (unsigned long)nav.viewControllers.count);
            [nav popViewControllerAnimated:YES];
        }
    }
}
@end
// ==================== 安装手势 ====================
static SEL FBSHandleTransitionSEL(void) {
    static SEL s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = NSSelectorFromString(@"handleNavigationTransition:"); });
    return s;
}
static void FBSInstallOnNav(UINavigationController *nav) {
    @try {
        // 转场进行中不碰手势（_layoutTopViewController在转场中频繁触发，此时增删手势会打断转场导致双pop）
        if (nav.transitionCoordinator) return;
        // 幂等：已装过就不再装（target固定为FBSDelegate，永不重装，杜绝重复手势/转场中重装）
        for (UIGestureRecognizer *g in nav.view.gestureRecognizers) {
            if ([g isMemberOfClass:[FBSPanGesture class]]) return;
        }
        
        FBSPanGesture *gesture = [[FBSPanGesture alloc] initWithTarget:[FBSDelegate shared]
                                                               action:@selector(drive:)];
        gesture.delegate = [FBSDelegate shared];
        gesture.maximumNumberOfTouches = 1;
        [gesture addTarget:[FBSHaptic shared] action:@selector(track:)];
        [gesture addTarget:[FBSDelegate shared] action:@selector(verify:)];
        [nav.view addGestureRecognizer:gesture];
        FBSLog(@"INSTALL drive nav=%@ stack=%lu", nav, (unsigned long)nav.viewControllers.count);
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
