/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVIonicKeyboard.h"
#import <Cordova/CDVAvailability.h>
#import <Cordova/NSDictionary+CordovaPreferences.h>
#import <objc/runtime.h>
#import <objc/message.h>

typedef enum : NSUInteger {
    ResizeNone,
    ResizeNative,
    ResizeBody,
    ResizeIonic,
} ResizePolicy;

#ifndef __CORDOVA_3_2_0
#warning "The keyboard plugin is only supported in Cordova 3.2 or greater, it may not work properly in an older version. If you do use this plugin in an older version, make sure the HideKeyboardFormAccessoryBar and KeyboardShrinksView preference values are false."
#endif

@interface CDVIonicKeyboard () <UIScrollViewDelegate>

@property (readwrite, assign, nonatomic) BOOL disableScroll;
@property (readwrite, assign, nonatomic) BOOL hideFormAccessoryBar;
@property (readwrite, assign, nonatomic) BOOL keyboardIsVisible;
@property (nonatomic, readwrite) ResizePolicy keyboardResizes;
@property (readwrite, assign, nonatomic) NSString* keyboardStyle;
@property (nonatomic, readwrite) BOOL isWK;
@property (nonatomic, readwrite) int paddingBottom;
@property (nonatomic, assign) NSTimeInterval lastHideAt;
@property (nonatomic, assign) BOOL inForceDismiss;

@end

// Weak reference to the most recently initialized plugin instance, used by the
// accessoryDone swizzle (a class-level callback) to reach a live instance and
// trigger the hard-dismiss path. Declared at file scope so it is visible from
// both -pluginInitialize and the class methods further below.
static __weak CDVIonicKeyboard *CDVIonicKeyboardSharedInstance = nil;

// In-app debug overlay: injects a fixed strip on top of the WKWebView and
// appends log lines to it. Designed for situations where the app is built in
// CI and the Xcode console / Console.app are not available. Always logs to
// NSLog too so production diagnostics still work when a Mac is attached.
@interface CDVIonicKeyboard (DebugOverlay)
+ (void)debugLog:(NSString *)message;
@end

@implementation CDVIonicKeyboard (DebugOverlay)

+ (void)debugLog:(NSString *)message
{
    NSLog(@"CDVIonicKeyboard: %@", message);

    CDVIonicKeyboard *plugin = CDVIonicKeyboardSharedInstance;
    if (!plugin) {
        return;
    }
    NSString *escaped = [[message stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                                  stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:
        @"(function(m){"
        "try {"
        "  var p = document.getElementById('cdv-ionic-kb-debug');"
        "  if (!p) {"
        "    p = document.createElement('div');"
        "    p.id = 'cdv-ionic-kb-debug';"
        "    p.style.cssText = 'position:fixed;top:env(safe-area-inset-top,0);left:0;right:0;z-index:2147483647;background:rgba(0,0,0,.8);color:#0f0;font:10px/1.25 monospace;padding:6px 8px;max-height:45%%;overflow:hidden;pointer-events:none;white-space:pre;text-align:left;';"
        "    (document.body || document.documentElement).appendChild(p);"
        "  }"
        "  var t = new Date();"
        "  var pad = function(n, w){ n = String(n); while (n.length < w) n = '0' + n; return n; };"
        "  var stamp = pad(t.getHours(),2)+':'+pad(t.getMinutes(),2)+':'+pad(t.getSeconds(),2)+'.'+pad(t.getMilliseconds(),3);"
        "  var line = '['+stamp+'] '+m;"
        "  var existing = p.textContent ? p.textContent.split('\\n') : [];"
        "  existing.unshift(line);"
        "  if (existing.length > 30) existing = existing.slice(0, 30);"
        "  p.textContent = existing.join('\\n');"
        "} catch(e) {}"
        "})('%@');", escaped];
    [plugin.commandDelegate evalJs:js];
}

@end

@implementation CDVIonicKeyboard

NSTimer *hideTimer;

- (id)settingForKey:(NSString *)key
{
    return [self.commandDelegate.settings objectForKey:[key lowercaseString]];
}

#pragma mark Initialize

NSString* UIClassString;
NSString* WKClassString;
NSString* UITraitsClassString;

- (void)pluginInitialize
{
    UIClassString = [@[@"UI", @"Web", @"Browser", @"View"] componentsJoinedByString:@""];
    WKClassString = [@[@"WK", @"Content", @"View"] componentsJoinedByString:@""];
    UITraitsClassString = [@[@"UI", @"Text", @"Input", @"Traits"] componentsJoinedByString:@""];

    NSDictionary *settings = self.commandDelegate.settings;

    self.disableScroll = ![settings cordovaBoolSettingForKey:@"ScrollEnabled" defaultValue:NO];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusBarDidChangeFrame:) name: UIApplicationDidChangeStatusBarFrameNotification object:nil];

    self.keyboardResizes = ResizeNative;
    BOOL doesResize = [settings cordovaBoolSettingForKey:@"KeyboardResize" defaultValue:YES];
    if (!doesResize) {
        self.keyboardResizes = ResizeNone;
        NSLog(@"CDVIonicKeyboard: no resize");

    } else {
        NSString *resizeMode = [settings cordovaSettingForKey:@"KeyboardResizeMode"];
        if (resizeMode) {
            if ([resizeMode isEqualToString:@"ionic"]) {
                self.keyboardResizes = ResizeIonic;
            } else if ([resizeMode isEqualToString:@"body"]) {
                self.keyboardResizes = ResizeBody;
            }
        }
        NSLog(@"CDVIonicKeyboard: resize mode %lu", (unsigned long)self.keyboardResizes);
    }
    self.hideFormAccessoryBar = [settings cordovaBoolSettingForKey:@"HideKeyboardFormAccessoryBar" defaultValue:YES];

    NSString *keyboardStyle = [settings cordovaSettingForKey:@"KeyboardStyle"];
    if (keyboardStyle) {
        [self setKeyboardStyle:keyboardStyle];
    }

    if ([settings cordovaBoolSettingForKey:@"KeyboardAppearanceDark" defaultValue:NO]) {
        [self setKeyboardStyle:@"dark"];
    }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    [nc addObserver:self selector:@selector(onKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardDidHide:) name:UIKeyboardDidHideNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(onKeyboardDidShow:) name:UIKeyboardDidShowNotification object:nil];

    // Prevent WKWebView to resize window
    BOOL isWK = self.isWK = [self.webView isKindOfClass:NSClassFromString(@"WKWebView")];
    if (!isWK) {
        NSLog(@"CDVIonicKeyboard: WARNING!!: Keyboard plugin works better with WK");
    }

    if (isWK) {
        [nc removeObserver:self.webView name:UIKeyboardWillHideNotification object:nil];
        [nc removeObserver:self.webView name:UIKeyboardWillShowNotification object:nil];
        [nc removeObserver:self.webView name:UIKeyboardWillChangeFrameNotification object:nil];
        [nc removeObserver:self.webView name:UIKeyboardDidChangeFrameNotification object:nil];
    }

    // iOS 26 regression workaround: see -installAccessoryDoneOverride.
    CDVIonicKeyboardSharedInstance = self;
    if (@available(iOS 16.0, *)) {
        [CDVIonicKeyboard installAccessoryDoneOverride];
    }
}

#pragma mark Accessory "Done" override (iOS 26 keyboard re-open workaround)

// In iOS 26.0 there is a WKWebView regression (rdar://162423793, WebKit bug 305617)
// where -[WKContentView accessoryViewDone:] does not reset _activeFocusedStateRetainCount.
// When that counter has been leaked (commonly by Safari AutoFill via -_retainActiveFocusedState),
// pressing "Done" causes WKWebView to immediately re-focus the input, re-opening the keyboard.
//
// We can't reset that private counter from a plugin, but we can ensure the keyboard
// is actually dismissed by sending -resignFirstResponder through the public responder
// chain right after WKWebView's own done logic runs. On iOS 26.1+ (Apple's fix) and
// earlier versions this is a harmless no-op because the first responder has already
// resigned, but on iOS 26.0 it pre-empts the spurious re-focus.
static IMP CDVIonicKeyboardOriginalAccessoryDoneImp = NULL;
static IMP CDVIonicKeyboardOriginalAccessoryViewDoneImp = NULL;

+ (void)installAccessoryDoneOverride
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class wkContentViewClass = NSClassFromString(WKClassString);
        if (!wkContentViewClass) {
            [CDVIonicKeyboard debugLog:@"WKContentView class not found, skipping accessoryDone swizzle"];
            return;
        }

        [CDVIonicKeyboard dumpKeyboardRelatedSelectorsForClass:wkContentViewClass];

        BOOL installed = NO;

        SEL accessoryDoneSel = NSSelectorFromString(@"accessoryDone");
        Method accessoryDoneMethod = class_getInstanceMethod(wkContentViewClass, accessoryDoneSel);
        if (accessoryDoneMethod) {
            CDVIonicKeyboardOriginalAccessoryDoneImp = method_getImplementation(accessoryDoneMethod);
            IMP newImp = imp_implementationWithBlock(^(id wkContentView) {
                [CDVIonicKeyboard debugLog:@"accessoryDone fired"];
                ((void (*)(id, SEL))CDVIonicKeyboardOriginalAccessoryDoneImp)(wkContentView, accessoryDoneSel);
                [CDVIonicKeyboard forceDismissAfterAccessoryDone];
            });
            method_setImplementation(accessoryDoneMethod, newImp);
            installed = YES;
        }

        SEL accessoryViewDoneSel = NSSelectorFromString(@"accessoryViewDone:");
        Method accessoryViewDoneMethod = class_getInstanceMethod(wkContentViewClass, accessoryViewDoneSel);
        if (accessoryViewDoneMethod) {
            CDVIonicKeyboardOriginalAccessoryViewDoneImp = method_getImplementation(accessoryViewDoneMethod);
            IMP newImp = imp_implementationWithBlock(^(id wkContentView, id view) {
                [CDVIonicKeyboard debugLog:@"accessoryViewDone: fired"];
                ((void (*)(id, SEL, id))CDVIonicKeyboardOriginalAccessoryViewDoneImp)(wkContentView, accessoryViewDoneSel, view);
                [CDVIonicKeyboard forceDismissAfterAccessoryDone];
            });
            method_setImplementation(accessoryViewDoneMethod, newImp);
            installed = YES;
        }

        [CDVIonicKeyboard debugLog:[NSString stringWithFormat:@"accessoryDone swizzle installed=%@", installed ? @"YES" : @"NO"]];
    });
}

// Diagnostic: enumerate every WKContentView instance method whose name contains
// "done", "accessory", "dismiss" or "keyboard". This tells us exactly which selector
// Apple is wiring the ✓ accessory button to in any given iOS version, so we can
// expand the swizzle list when a new one appears.
+ (void)dumpKeyboardRelatedSelectorsForClass:(Class)cls
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;

    NSArray<NSString *> *needles = @[@"done", @"accessory", @"dismiss", @"keyboard"];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = [name lowercaseString];
        for (NSString *needle in needles) {
            if ([lower containsString:needle]) {
                [CDVIonicKeyboard debugLog:[NSString stringWithFormat:@"WKContentView selector: %@", name]];
                break;
            }
        }
    }
    free(methods);
}

+ (void)forceDismissAfterAccessoryDone
{
    CDVIonicKeyboard *plugin = CDVIonicKeyboardSharedInstance;
    if (plugin) {
        [plugin hardDismissKeyboard];
    }
}

// Hard dismiss: combines every public + private mechanism that has been
// observed to release the focused element on iOS 16–26.x. Called from both
// the accessoryDone swizzle and the spurious-reopen detector in
// onKeyboardWillShow:.
- (void)hardDismissKeyboard
{
    UIView *webView = (UIView *)self.webView;

    // 1) Apple's own fix (iOS 26.1+). The selector lives on WKWebView. We
    //    call it dynamically so the plugin keeps building against older SDKs.
    //    On iOS versions where the selector is absent this is a silent no-op.
    SEL fullResetSel = NSSelectorFromString(@"_resetFocusPreservationCountAndReleaseActiveFocusState");
    SEL legacyResetSel = NSSelectorFromString(@"_resetFocusPreservationCount");
    if ([webView respondsToSelector:fullResetSel]) {
        [CDVIonicKeyboard debugLog:@"calling _resetFocusPreservationCountAndReleaseActiveFocusState"];
        ((void (*)(id, SEL))objc_msgSend)(webView, fullResetSel);
    } else if ([webView respondsToSelector:legacyResetSel]) {
        [CDVIonicKeyboard debugLog:@"calling _resetFocusPreservationCount (legacy)"];
        ((void (*)(id, SEL))objc_msgSend)(webView, legacyResetSel);
    } else {
        [CDVIonicKeyboard debugLog:@"no private reset selector available on WKWebView"];
    }

    // 2) Standard public dismissal paths.
    [webView endEditing:YES];
    [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder)
                                               to:nil from:nil forEvent:nil];

    // 3) JS guarantee: blur the active element AND temporarily make it
    //    non-focusable for 500ms via tabindex=-1, so WebKit cannot re-focus
    //    it (the redesigned iOS 26 password AutoFill is the prime suspect).
    NSString *js = @"(function(){"
        "try {"
        "  var el = document.activeElement;"
        "  if (!el || el === document.body) return;"
        "  var tag = el.tagName;"
        "  var editable = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable === true;"
        "  if (!editable) return;"
        "  var prev = el.getAttribute('tabindex');"
        "  el.setAttribute('tabindex', '-1');"
        "  if (typeof el.blur === 'function') el.blur();"
        "  setTimeout(function(){"
        "    if (prev === null) el.removeAttribute('tabindex');"
        "    else el.setAttribute('tabindex', prev);"
        "  }, 500);"
        "} catch (e) {}"
        "})();";
    [self.commandDelegate evalJs:js];
}

-(void)statusBarDidChangeFrame:(NSNotification*)notification
{
    [self _updateFrame];
}


#pragma mark Keyboard events

- (void)resetScrollView
{
    UIScrollView *scrollView = [self.webView scrollView];
    [scrollView setContentInset:UIEdgeInsetsZero];
}

- (void)onKeyboardWillHide:(NSNotification *)sender
{
    if (self.isWK) {
        [self setKeyboardHeight:0 delay:0.01];
        [self resetScrollView];
    }

    // iOS 16+ workaround: when the keyboard is dismissed (e.g. via the "Done" button) WKWebView
    // does not blur the focused HTML element automatically. As a result the element keeps the
    // focus and the keyboard can remain visible or reappear. Force a blur on the active element
    // when it is an editable one. Safe for iOS 16 onwards (including iOS 26+).
    if (@available(iOS 16.0, *)) {
        [self blurActiveEditableElement];
    }

    // Record the time of this hide so onKeyboardWillShow: can detect spurious "reopens"
    // (e.g. iOS 26 password AutoFill re-focusing the input after Done was pressed).
    if (!self.inForceDismiss) {
        self.lastHideAt = [[NSDate date] timeIntervalSince1970];
    }
    [CDVIonicKeyboard debugLog:[NSString stringWithFormat:@"willHide (forced=%@)", self.inForceDismiss ? @"YES" : @"NO"]];

    hideTimer = [NSTimer scheduledTimerWithTimeInterval:0 target:self selector:@selector(fireOnHiding) userInfo:nil repeats:NO];
}

- (void)blurActiveEditableElement
{
    NSString *blurJs = @"(function(){"
        "try {"
        "  var el = document.activeElement;"
        "  if (!el || el === document.body) { return; }"
        "  var tag = el.tagName;"
        "  var isEditable = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable === true;"
        "  if (isEditable && typeof el.blur === 'function') { el.blur(); }"
        "} catch (e) {}"
        "})();";
    [self.commandDelegate evalJs:blurJs];
}

- (void)fireOnHiding {
    [self.commandDelegate evalJs:@"Keyboard.fireOnHiding();"];
}

- (void)onKeyboardWillShow:(NSNotification *)note
{
    if (hideTimer != nil) {
        [hideTimer invalidate];
    }

    NSTimeInterval elapsedSinceHide = self.lastHideAt > 0
        ? ([[NSDate date] timeIntervalSince1970] - self.lastHideAt)
        : -1;
    [CDVIonicKeyboard debugLog:[NSString stringWithFormat:@"willShow (sinceHide=%.0fms, forced=%@)",
                                elapsedSinceHide * 1000, self.inForceDismiss ? @"YES" : @"NO"]];

    // iOS 26 safety net: if a WillShow notification arrives shortly after a WillHide
    // and we are not currently in the middle of a forced dismiss, treat it as a spurious
    // reopen (e.g. password AutoFill re-focusing the input after the user pressed Done in
    // the accessory bar) and force the keyboard back down using every public+private
    // mechanism we have. Genuine field-to-field switches normally fire
    // UIKeyboardWillChangeFrame instead of a hide/show pair, so this window should not
    // trigger on legitimate cases. The 1.0s window is intentionally generous to cover
    // the slower iOS 26.4 animation timings observed in the wild.
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval elapsed = now - self.lastHideAt;
    if (self.lastHideAt > 0 && elapsed < 1.0 && !self.inForceDismiss) {
        [CDVIonicKeyboard debugLog:[NSString stringWithFormat:@"spurious reopen detected (%.0fms after hide), forcing dismiss", elapsed * 1000]];
        self.lastHideAt = 0;
        self.inForceDismiss = YES;
        __weak CDVIonicKeyboard *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [CDVIonicKeyboard hardDismissKeyboard:weakSelf.commandDelegate];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                weakSelf.inForceDismiss = NO;
            });
        });
        return;
    }

    CGRect rect = [[note.userInfo valueForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double height = rect.size.height;

    if (self.isWK) {
        double duration = [[note.userInfo valueForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        [self setKeyboardHeight:height delay:duration+0.2];
        [self resetScrollView];
    }
    
    [self setKeyboardStyle:self.keyboardStyle];

    NSString *js = [NSString stringWithFormat:@"Keyboard.fireOnShowing(%d);", (int)height];
    [self.commandDelegate evalJs:js];
}

- (void)onKeyboardDidShow:(NSNotification *)note
{
    CGRect rect = [[note.userInfo valueForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double height = rect.size.height;

    if (self.isWK) {
        [self resetScrollView];
    }

    NSString *js = [NSString stringWithFormat:@"Keyboard.fireOnShow(%d);", (int)height];
    [self.commandDelegate evalJs:js];
}

- (void)onKeyboardDidHide:(NSNotification *)sender
{
    [self.commandDelegate evalJs:@"Keyboard.fireOnHide();"];
    [self resetScrollView];
}

- (void)setKeyboardHeight:(int)height delay:(NSTimeInterval)delay
{
    if (self.keyboardResizes != ResizeNone) {
        [self setPaddingBottom: height delay:delay];
    }
}

- (void)setPaddingBottom:(int)paddingBottom delay:(NSTimeInterval)delay
{
    if (self.paddingBottom == paddingBottom) {
        return;
    }

    self.paddingBottom = paddingBottom;

    __weak CDVIonicKeyboard* weakSelf = self;
    SEL action = @selector(_updateFrame);
    [NSObject cancelPreviousPerformRequestsWithTarget:weakSelf selector:action object:nil];
    if (delay == 0) {
        [self _updateFrame];
    } else {
        [weakSelf performSelector:action withObject:nil afterDelay:delay];
    }
}

- (void)_updateFrame
{
    CGSize statusBarSize = [[UIApplication sharedApplication] statusBarFrame].size;
    int statusBarHeight = MIN(statusBarSize.width, statusBarSize.height);
    
    int _paddingBottom = (int)self.paddingBottom;
        
    if (statusBarHeight == 40) {
        _paddingBottom = _paddingBottom + 20;
    }
    NSLog(@"CDVIonicKeyboard: updating frame");
    // NOTE: to handle split screen correctly, the application's window bounds must be used as opposed to the screen's bounds.
    CGRect f = [[[[UIApplication sharedApplication] delegate] window] bounds];
    CGRect wf = self.webView.frame;
    switch (self.keyboardResizes) {
        case ResizeBody:
        {
            NSString *js = [NSString stringWithFormat:@"Keyboard.fireOnResize(%d, %d, document.body);",
                            _paddingBottom, (int)f.size.height];
            [self.commandDelegate evalJs:js];
            break;
        }
        case ResizeIonic:
        {
            NSString *js = [NSString stringWithFormat:@"Keyboard.fireOnResize(%d, %d, document.querySelector('ion-app'));",
                            _paddingBottom, (int)f.size.height];
            [self.commandDelegate evalJs:js];
            break;
        }
        case ResizeNative:
        {
            [self.webView setFrame:CGRectMake(wf.origin.x, wf.origin.y, f.size.width - wf.origin.x, f.size.height - wf.origin.y - self.paddingBottom)];
            break;
        }
        default:
            break;
    }
    [self resetScrollView];
}

#pragma mark Keyboard Style

 - (void)setKeyboardStyle:(NSString*)style
{
    IMP newImp = [style isEqualToString:@"dark"] ? imp_implementationWithBlock(^(id _s) {
        return UIKeyboardAppearanceDark;
    }) : imp_implementationWithBlock(^(id _s) {
        return UIKeyboardAppearanceLight;
    });
    
    if (self.isWK) {
        for (NSString* classString in @[WKClassString, UITraitsClassString]) {
            Class c = NSClassFromString(classString);
            Method m = class_getInstanceMethod(c, @selector(keyboardAppearance));
            
            if (m != NULL) {
                method_setImplementation(m, newImp);
            } else {
                class_addMethod(c, @selector(keyboardAppearance), newImp, "l@:");
            }
        }
    }
    else {
        for (NSString* classString in @[UIClassString, UITraitsClassString]) {
            Class c = NSClassFromString(classString);
            Method m = class_getInstanceMethod(c, @selector(keyboardAppearance));
            
            if (m != NULL) {
                method_setImplementation(m, newImp);
            } else {
                class_addMethod(c, @selector(keyboardAppearance), newImp, "l@:");
            }
        }
    }

    _keyboardStyle = style;
}

#pragma mark HideFormAccessoryBar

static IMP UIOriginalImp;
static IMP WKOriginalImp;

- (void)setHideFormAccessoryBar:(BOOL)hideFormAccessoryBar
{
    if (hideFormAccessoryBar == _hideFormAccessoryBar) {
        return;
    }

    Method UIMethod = class_getInstanceMethod(NSClassFromString(UIClassString), @selector(inputAccessoryView));
    Method WKMethod = class_getInstanceMethod(NSClassFromString(WKClassString), @selector(inputAccessoryView));

    if (hideFormAccessoryBar) {
        UIOriginalImp = method_getImplementation(UIMethod);
        WKOriginalImp = method_getImplementation(WKMethod);

        IMP newImp = imp_implementationWithBlock(^(id _s) {
            return nil;
        });

        method_setImplementation(UIMethod, newImp);
        method_setImplementation(WKMethod, newImp);
    } else {
        method_setImplementation(UIMethod, UIOriginalImp);
        method_setImplementation(WKMethod, WKOriginalImp);
    }

    _hideFormAccessoryBar = hideFormAccessoryBar;
}

#pragma mark scroll

- (void)setDisableScroll:(BOOL)disableScroll {
    if (disableScroll == _disableScroll) {
        return;
    }
    if (disableScroll) {
        self.webView.scrollView.scrollEnabled = NO;
        self.webView.scrollView.delegate = self;
    }
    else {
        self.webView.scrollView.scrollEnabled = YES;
        self.webView.scrollView.delegate = nil;
    }
    _disableScroll = disableScroll;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [scrollView setContentOffset: CGPointZero];
}

#pragma mark Plugin interface

- (void)hideFormAccessoryBar:(CDVInvokedUrlCommand *)command
{
    if (command.arguments.count > 0) {
        id value = [command.arguments objectAtIndex:0];
        if (!([value isKindOfClass:[NSNumber class]])) {
            value = [NSNumber numberWithBool:NO];
        }

        self.hideFormAccessoryBar = [value boolValue];
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:self.hideFormAccessoryBar]
                                callbackId:command.callbackId];
}

- (void)hide:(CDVInvokedUrlCommand *)command
{
    [self.webView endEditing:YES];

    // On iOS 16+ endEditing: does not always remove the focus from the underlying HTML element,
    // so the keyboard may stay visible. Force a blur on the active element from JS too.
    if (@available(iOS 16.0, *)) {
        [self blurActiveEditableElement];
    }
}

- (void)setResizeMode:(CDVInvokedUrlCommand *)command
{
    NSString * mode = [command.arguments objectAtIndex:0];
    if ([mode isEqualToString:@"ionic"]) {
        self.keyboardResizes = ResizeIonic;
    } else if ([mode isEqualToString:@"body"]) {
        self.keyboardResizes = ResizeBody;
    } else if ([mode isEqualToString:@"native"]) {
        self.keyboardResizes = ResizeNative;
    } else {
        self.keyboardResizes = ResizeNone;
    }
}

- (void)keyboardStyle:(CDVInvokedUrlCommand*)command
{
    id value = [command.arguments objectAtIndex:0];
    if ([value isKindOfClass:[NSString class]]) {
        value = [(NSString*)value lowercaseString];
    } else {
        value = @"light";
    }

     self.keyboardStyle = value;
}

- (void)disableScroll:(CDVInvokedUrlCommand*)command {
    if (!command.arguments || ![command.arguments count]){
        return;
    }
    id value = [command.arguments objectAtIndex:0];
    if (value != [NSNull null]) {
        self.disableScroll = [value boolValue];
    }
}

#pragma mark dealloc

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
