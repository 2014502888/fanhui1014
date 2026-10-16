#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

// ============================================================================
//  FullScreenBackTweak —— Telegram 移植融合版
//  判定逻辑完整移植 Telegram Display.InteractiveTransitionGestureRecognizer：
//    - 方向系统（左/右/中心/边缘/下滑）
//    - 页面禁用树（disables/Now/Test 递归 superview，strict 全禁/some 降级边缘）
//    - 边缘让位（左边缘必须配 rightEdge，自动让位给系统边缘返回）
//    - 10pt 主导方向状态机（validatedGesture + fireBegan）
//  保留本 tweak 优势：
//    - 绑定系统转场 target（handleNavigationTransition:，跟手动画）
//    - 震动恒开满格 1.0
//    - 全量遍历 + pushViewController/viewDidAppear 双 hook + 幂等安装
// ============================================================================

// -------------------- 方向（Telegram InteractiveTransitionGestureRecognizerDirections） --------------------
typedef NS_OPTIONS(NSUInteger, FSBDirections) {
    FSBDirectionsLeftEdge    = 1 << 2,
    FSBDirectionsRightEdge   = 1 << 3,
    FSBDirectionsLeftCenter  = 1 << 0,
    FSBDirectionsRightCenter = 1 << 1,
    FSBDirectionsDown        = 1 << 4,
    FSBDirectionsLeft  = FSBDirectionsLeftEdge  | FSBDirectionsLeftCenter,
    FSBDirectionsRight = FSBDirectionsRightEdge | FSBDirectionsRightCenter,
};

// -------------------- 边缘宽度（Telegram InteractiveTransitionGestureRecognizerEdgeWidth） --------------------
typedef NS_ENUM(NSInteger, FSBEdgeWidthMode) {
    FSBEdgeWidthConstant,
    FSBEdgeWidthMultiplier,
};
@interface FSBEdgeWidth : NSObject
@property (nonatomic) FSBEdgeWidthMode mode;
@property (nonatomic) CGFloat constantValue;
@property (nonatomic) CGFloat factor, minValue, maxValue;
+ (instancetype)constant:(CGFloat)value;
+ (instancetype)widthMultiplierWithFactor:(CGFloat)factor min:(CGFloat)min max:(CGFloat)max;
- (CGFloat)valueForWidth:(CGFloat)width;
@end
@implementation FSBEdgeWidth
+ (instancetype)constant:(CGFloat)value {
    FSBEdgeWidth *e = [FSBEdgeWidth new];
    e.mode = FSBEdgeWidthConstant;
    e.constantValue = value;
    return e;
}
+ (instancetype)widthMultiplierWithFactor:(CGFloat)factor min:(CGFloat)min max:(CGFloat)max {
    FSBEdgeWidth *e = [FSBEdgeWidth new];
    e.mode = FSBEdgeWidthMultiplier;
    e.factor = factor;
    e.minValue = min;
    e.maxValue = max;
    return e;
}
- (CGFloat)valueForWidth:(CGFloat)width {
    if (self.mode == FSBEdgeWidthConstant) return self.constantValue;
    return MAX(self.minValue, MIN(width * self.factor, self.maxValue));
}
@end

// -------------------- UIView 页面禁用机制（Telegram disablesInteractiveTransitionGestureRecognizer） --------------------
//  关联属性：fsb_disables(NSNumber BOOL) / fsb_disablesNow(block) / fsb_test(block)
typedef NS_ENUM(NSInteger, FSBHorizontalState) {
    FSBHorizontalNone,
    FSBHorizontalSome,   // 降级：只留边缘
    FSBHorizontalStrict, // 完全禁用
};

static const void *kFSBDisablesKey   = &kFSBDisablesKey;
static const void *kFSBDisablesNowKey = &kFSBDisablesNowKey;
static const void *kFSBTestKey       = &kFSBTestKey;

static FSBHorizontalState FSBHasHorizontalGestures(UIView *view, CGPoint *point) {
    if (!view) return FSBHorizontalNone;

    BOOL (^nowBlock)(void) = objc_getAssociatedObject(view, kFSBDisablesNowKey);
    if (nowBlock && nowBlock()) return FSBHorizontalStrict;

    NSNumber *dis = objc_getAssociatedObject(view, kFSBDisablesKey);
    if (dis && dis.boolValue) return FSBHorizontalSome;

    if (point) {
        BOOL (^test)(CGPoint) = objc_getAssociatedObject(view, kFSBTestKey);
        if (test && test(*point)) return FSBHorizontalSome;
    }

    // 90° 旋转视图（横滚列表）降级——通用化 Telegram ListViewBackingView 检查
    CGAffineTransform tf = view.transform;
    double angle = atan2(tf.b, tf.a);
    double t1 = fabs(angle - M_PI_2), t2 = fabs(angle + M_PI_2), t3 = fabs(angle - M_PI * 1.5);
    if (t1 < 0.001 || t2 < 0.001 || t3 < 0.001) return FSBHorizontalSome;

    if (view.superview) {
        CGPoint converted = point ? [view convertPoint:*point toView:view.superview] : CGPointZero;
        return FSBHasHorizontalGestures(view.superview, point ? &converted : NULL);
    }
    return FSBHorizontalNone;
}

// -------------------- 震动（恒开满格 1.0，保留） --------------------
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
            BOOL passed = (w > 0.0 && tx > w * 0.35) || vx > 300.0;
            if (passed) {
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

// -------------------- 手势（Telegram InteractiveTransitionGestureRecognizer 完整移植） --------------------
@interface FSBInteractivePan : UIPanGestureRecognizer
@property (nonatomic, strong) FSBEdgeWidth *edgeWidth;
@property (nonatomic, copy) FSBDirections (^allowedDirectionsBlock)(CGPoint point);
@property (nonatomic, readonly) FSBDirections currentAllowedDirections;
@end

@implementation FSBInteractivePan {
    BOOL _validatedGesture;
    CGPoint _firstLocation;
    FSBDirections _currentAllowedDirections;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if (self = [super initWithTarget:target action:action]) {
        _edgeWidth = [FSBEdgeWidth constant:16.0];
        _allowedDirectionsBlock = ^FSBDirections(CGPoint p) { return FSBDirectionsRight; }; // 默认全屏向右
        self.maximumNumberOfTouches = 1;
        self.delaysTouchesBegan = NO;
    }
    return self;
}

- (void)reset {
    [super reset];
    _validatedGesture = NO;
    _currentAllowedDirections = 0;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self.view];

    FSBDirections allowed = self.allowedDirectionsBlock(point);
    if (allowed == 0) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }

    [super touchesBegan:touches withEvent:event];

    _firstLocation = point;

    UIView *target = [self.view hitTest:_firstLocation withEvent:event];
    if (target) {
        CGPoint converted = [self.view convertPoint:_firstLocation toView:target];
        FSBHorizontalState hs = FSBHasHorizontalGestures(target, &converted);
        if (hs != FSBHorizontalNone) {
            if (allowed & FSBDirectionsDown) {
                // down 方向不降级
            } else {
                if (hs == FSBHorizontalStrict) {
                    allowed = 0;
                } else if ((allowed & FSBDirectionsLeftEdge) || (allowed & FSBDirectionsRightEdge)) {
                    allowed &= ~FSBDirectionsLeftCenter;
                    allowed &= ~FSBDirectionsRightCenter;
                }
            }
        }
    }

    if (allowed == 0) {
        self.state = UIGestureRecognizerStateFailed;
    } else {
        _currentAllowedDirections = allowed;
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    CGPoint location = [touch locationInView:self.view];
    CGPoint translation = CGPointMake(location.x - _firstLocation.x, location.y - _firstLocation.y);

    CGFloat absX = fabs(translation.x), absY = fabs(translation.y);
    CGSize size = self.view ? self.view.bounds.size : CGSizeZero;

    BOOL fireBegan = NO;

    if (_currentAllowedDirections & FSBDirectionsDown) {
        if (!_validatedGesture) {
            CGFloat total = sqrt(absX * absX + absY * absY);
            if (total > 10.0) {
                if (absY >= absX) {
                    _validatedGesture = YES;
                } else {
                    self.state = UIGestureRecognizerStateFailed;
                }
            } else if (absX > 2.0 && absX > absY * 2.0) {
                self.state = UIGestureRecognizerStateFailed;
            } else if (absY > 2.0 && absX * 2.0 < absY) {
                _validatedGesture = YES;
            }
        }
    } else {
        CGFloat edgeWidth = [self.edgeWidth valueForWidth:size.width];

        if (!_validatedGesture) {
            if (_firstLocation.x < edgeWidth && !(_currentAllowedDirections & FSBDirectionsRightEdge)) {
                self.state = UIGestureRecognizerStateFailed;
                return;
            }
            if (_firstLocation.x > size.width - edgeWidth && !(_currentAllowedDirections & FSBDirectionsLeftEdge)) {
                self.state = UIGestureRecognizerStateFailed;
                return;
            }

            if ((_currentAllowedDirections & FSBDirectionsRightEdge) && _firstLocation.x < edgeWidth) {
                _validatedGesture = YES;
            } else if ((_currentAllowedDirections & FSBDirectionsLeftEdge) && _firstLocation.x > size.width - edgeWidth) {
                _validatedGesture = YES;
            } else if (!(_currentAllowedDirections & FSBDirectionsLeftCenter) && translation.x < 0.0) {
                self.state = UIGestureRecognizerStateFailed;
            } else if (!(_currentAllowedDirections & FSBDirectionsRightCenter) && translation.x > 0.0) {
                self.state = UIGestureRecognizerStateFailed;
            } else {
                CGFloat total = sqrt(absX * absX + absY * absY);
                if (total > 10.0) {
                    if (absX >= absY) {
                        _validatedGesture = YES;
                        fireBegan = YES;
                    } else {
                        self.state = UIGestureRecognizerStateFailed;
                    }
                } else if (absY > 2.0 && absY > absX * 2.0) {
                    self.state = UIGestureRecognizerStateFailed;
                } else if (absX > 2.0 && absY * 2.0 < absX) {
                    _validatedGesture = YES;
                    fireBegan = YES;
                }
            }
        }
    }

    if (_validatedGesture) {
        [super touchesMoved:touches withEvent:event];
        if (fireBegan) {
            if (self.state == UIGestureRecognizerStatePossible) {
                self.state = UIGestureRecognizerStateBegan;
            }
        }
    }
}
@end

// -------------------- 导航定位 --------------------
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

// -------------------- 手势 delegate（导航级粗过滤；方向细判交给 touchesMoved） --------------------
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

    UINavigationController *nav = FSBNavForView(g.view);
    if (!nav) return NO;
    if (nav.viewControllers.count < 2) return NO;      // 栈底不响应
    if (nav.transitionCoordinator != nil) return NO;   // 转场中不响应
    if (nav.presentedViewController != nil) return NO; // 模态盖着不响应
    if (nav.isBeingDismissed || nav.isBeingPresented) return NO;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
@end

// -------------------- 系统转场 target（跟手根本，保留） --------------------
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

// -------------------- 安装（幂等） --------------------
static void FSBInstallOnNav(UINavigationController *nav) {
    if (!nav || ![nav isKindOfClass:[UINavigationController class]]) return;
    UIView *host = nav.view;
    if (!host) return;
    if (nav.viewControllers.count < 2) return;

    for (UIGestureRecognizer *g in host.gestureRecognizers) {
        if ([g isKindOfClass:[FSBInteractivePan class]]) return;   // 已装
    }

    id target = FSBSystemTransitionTarget(nav);
    if (!target || ![target respondsToSelector:NSSelectorFromString(@"handleNavigationTransition:")]) return;

    FSBInteractivePan *pan = [[FSBInteractivePan alloc] initWithTarget:target
                                                                 action:NSSelectorFromString(@"handleNavigationTransition:")];
    pan.delegate = [FSBGestureDelegate shared];
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
static IMP gSwizzleOrig[2];

#define SW_NAV_PUSH          0
#define SW_VC_VIEWDIDAPPEAR  1

static void FSB_UINavigationController_pushViewController(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    IMP o = gSwizzleOrig[SW_NAV_PUSH];
    if (o) ((void (*)(id, SEL, id, BOOL))o)(self, _cmd, vc, animated);
    FSBInstallOnNav(self);
}
static void FSB_UIViewController_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    IMP o = gSwizzleOrig[SW_VC_VIEWDIDAPPEAR];
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
    UINavigationController *nav = ((UIViewController *)self).navigationController;
    if (nav) FSBInstallOnNav(nav);
}

static IMP FSBReplace(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        class_addMethod(cls, sel, newImp, "@@:");
        return NULL;
    }
    IMP orig = method_getImplementation(m);
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
    return orig;
}

__attribute__((constructor)) static void FSBEntry(void) {
    @autoreleasepool {
        gSwizzleOrig[SW_NAV_PUSH] = FSBReplace(objc_getClass("UINavigationController"),
                                               sel_registerName("pushViewController:animated:"),
                                               (IMP)FSB_UINavigationController_pushViewController);
        gSwizzleOrig[SW_VC_VIEWDIDAPPEAR] = FSBReplace(objc_getClass("UIViewController"),
                                                       sel_registerName("viewDidAppear:"),
                                                       (IMP)FSB_UIViewController_viewDidAppear);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ FSBInstallAll(); });
    }
}
