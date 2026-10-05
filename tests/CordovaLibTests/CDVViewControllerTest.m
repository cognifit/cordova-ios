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

#import <XCTest/XCTest.h>
#import <WebKit/WebKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "CDVTestHelpers.h"
#import <Cordova/CDVPlugin.h>
#import <Cordova/CDVViewController.h>
#import <Cordova/CDVSecondaryWebViewStreams.h>
#import <math.h>
#import "CDVViewController+Private.h"
#import <Cordova/CDVPluginNotifications.h>

#define CDVViewControllerTestSettingKey @"test_cdvconfigfile"
#define CDVViewControllerTestSettingValueDefault @"config.xml"
#define CDVViewControllerTestSettingValueCustom @"config-custom.xml"

// Internal clock seam for deterministic producer-gate tests; not part of the public API.
@interface CDVSecondaryStreamRateGate : NSObject
- (BOOL)reserveAtTime:(NSTimeInterval)now rateHz:(double)rateHz;
- (void)finishValid:(BOOL)valid;
@end

// Exercise the private state machine separately from simulator input timing.
@interface CDVSecondaryCancelGesture : UIGestureRecognizer
@property (nonatomic, strong) NSMutableSet<UITouch *> *activeTouches;
- (void)cancelActiveTouches;
- (void)setTrackingEnabled:(BOOL)enabled;
@end

@interface CDVSecondaryCancelGestureProbe : CDVSecondaryCancelGesture
@property (nonatomic) UIGestureRecognizerState lastRequestedState;
@end
@implementation CDVSecondaryCancelGestureProbe
- (void)setState:(UIGestureRecognizerState)state {
    self.lastRequestedState = state;
    [super setState:state];
}
@end

@interface CDVViewControllerTest : XCTestCase

@end

@interface CDVViewController ()

// expose private interface
- (bool)checkAndReinitViewUrl;
- (bool)isUrlEmpty:(NSURL*)url;

@end

@implementation CDVViewControllerTest

- (void)testSecondaryTouchCancellationLifecycle
{
    CDVSecondaryCancelGestureProbe *gesture = [CDVSecondaryCancelGestureProbe new];
    NSSet<UITouch *> *touches = [NSSet setWithObject:[UITouch new]];
    [gesture touchesBegan:touches withEvent:nil];
    XCTAssertEqual(gesture.activeTouches.count, 1U);
    [gesture reset];
    XCTAssertEqual(gesture.activeTouches.count, 0U);

    [gesture touchesBegan:touches withEvent:nil];
    [gesture touchesEnded:touches withEvent:nil];
    // Without a live UIKit event, the framework may reset immediately to Possible.
    XCTAssertEqual(gesture.lastRequestedState, UIGestureRecognizerStateFailed);
    [gesture setTrackingEnabled:YES];
    XCTAssertEqual(gesture.state, UIGestureRecognizerStatePossible);
    [gesture cancelActiveTouches];
    XCTAssertEqual(gesture.state, UIGestureRecognizerStatePossible);

    [gesture touchesBegan:touches withEvent:nil];
    [gesture cancelActiveTouches];
    XCTAssertEqual(gesture.lastRequestedState, UIGestureRecognizerStateRecognized);
    XCTAssertEqual(gesture.activeTouches.count, 0U);
    [gesture setTrackingEnabled:NO];
    XCTAssertFalse(gesture.enabled);
    XCTAssertEqual(gesture.activeTouches.count, 0U);
    [gesture setTrackingEnabled:YES];
    XCTAssertTrue(gesture.enabled);
    XCTAssertEqual(gesture.state, UIGestureRecognizerStatePossible);
}

- (void)testCurrentWindowDoesNotLoadView
{
    CDVViewController *controller = [self viewController];
    (void)controller.currentWindow;
    XCTAssertFalse(controller.isViewLoaded);
}

- (void)testCurrentWindowFollowsAttachedViewAndPluginDisposal
{
    CDVViewController *controller = [self viewController];
    controller.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    UIWindow *first = [[UIWindow alloc] initWithFrame:controller.view.bounds];
    UIWindow *second = [[UIWindow alloc] initWithFrame:controller.view.bounds];
    CDVPlugin *plugin = [CDVPlugin new];
    XCTAssertNil(plugin.currentWindow);
    plugin.viewController = controller;

    [first addSubview:controller.view];
    XCTAssertEqual(controller.currentWindow, first);
    XCTAssertEqual(plugin.currentWindow, first);

    [second addSubview:controller.view];
    XCTAssertEqual(controller.currentWindow, second);
    XCTAssertEqual(plugin.currentWindow, second);

    [plugin dispose];
    XCTAssertNil(plugin.currentWindow);
    [controller.view removeFromSuperview];
}

-(CDVViewController*)viewController{
    CDVViewController* viewController = [CDVViewController new];
    return viewController;
}

-(void)doTestInitWithConfigFile:(NSString*)configFile expectedSettingValue:(NSString*)value{
    // Create a CDVViewController
    CDVViewController* viewController = [self viewController];
    if(configFile){
        // Set custom config file
        viewController.configFile = configFile;
    }else{
        // Do not specify config file ==> fallback to default config.xml
    }

    // Trigger -viewDidLoad
    [viewController view];

    // Assert that the proper file was actually loaded, checking the value of a test setting it must contain
    NSString* settingValue = [viewController.settings objectForKey:CDVViewControllerTestSettingKey];
    XCTAssertEqualObjects(settingValue, value);
}

-(void)testInitWithDefaultConfigFile{
    [self doTestInitWithConfigFile:nil expectedSettingValue:CDVViewControllerTestSettingValueDefault];
}

-(void)testInitWithCustomConfigFileAbsolutePath{
    NSString* configFileAbsolutePath = [[NSBundle mainBundle] pathForResource:@"config-custom" ofType:@"xml"];
    [self doTestInitWithConfigFile:configFileAbsolutePath expectedSettingValue:CDVViewControllerTestSettingValueCustom];
}

-(void)testInitWithCustomConfigFileRelativePath{
    NSString* configFileRelativePath = @"config-custom.xml";
    [self doTestInitWithConfigFile:configFileRelativePath expectedSettingValue:CDVViewControllerTestSettingValueCustom];
}

-(void)testIsUrlEmpty{
    CDVViewController* viewController = [self viewController];
    XCTAssertTrue([viewController isUrlEmpty:(id)[NSNull null]]);
    XCTAssertTrue([viewController isUrlEmpty:nil]);
    XCTAssertTrue([viewController isUrlEmpty:[NSURL URLWithString:@""]]);
    XCTAssertTrue([viewController isUrlEmpty:[NSURL URLWithString:@"about:blank"]]);
}

-(void)testIfItLoadsAppUrlIfCurrentViewIsBlank{
    CDVViewController* viewController = [self viewController];

    NSString* appUrl = @"about:blank";
    NSString* html = @"<html><body></body></html>";
    [viewController.webViewEngine loadHTMLString:html baseURL:[NSURL URLWithString:appUrl]];
    XCTAssertFalse([viewController checkAndReinitViewUrl]);

    appUrl = @"https://cordova.apache.org";
    viewController.startPage = appUrl;
    [viewController.webViewEngine loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:appUrl]]];
    XCTAssertTrue([viewController checkAndReinitViewUrl]);
}

- (void)testLoadingScreenIsLazyAndCustomHTMLUsesSeparateWebView
{
    CDVViewController *controller = [self viewController];
    XCTestExpectation *appLoaded = [self expectationForNotification:CDVPageDidLoadNotification object:nil handler:^BOOL(NSNotification *note) {
        return note.object == controller.webView;
    }];
    [controller loadViewIfNeeded];
    [self waitForExpectations:@[appLoaded] timeout:15];
    XCTAssertNil([controller valueForKey:@"backgroundView"]);
    UIView *appWebView = controller.webView;
    NSNumber *loadCount = [controller valueForKey:@"loadCounter"];

    [controller showLoadingScreenWithHTML:nil baseURL:nil];
    UIView *nativeOverlay = [controller valueForKey:@"backgroundView"];
    XCTAssertTrue([nativeOverlay.subviews.firstObject isKindOfClass:UIActivityIndicatorView.class]);
    XCTAssertEqual(controller.webView, appWebView);
    [controller hideLoadingScreen];
    XCTAssertNil(nativeOverlay.superview);

    [controller showLoadingScreenWithHTML:@"<!doctype html><title>App loading screen</title><body>Loading</body>" baseURL:[NSURL URLWithString:@"https://assets.example/brand/"]];
    UIView *htmlOverlay = [controller valueForKey:@"backgroundView"];
    WKWebView *loadingWebView = (WKWebView *)htmlOverlay.subviews.firstObject;
    XCTAssertTrue([loadingWebView isKindOfClass:WKWebView.class]);
    XCTAssertNotEqual(loadingWebView, appWebView);
    XCTAssertFalse(loadingWebView.configuration.websiteDataStore.isPersistent);
    XCTAssertEqual(loadingWebView.configuration.userContentController.userScripts.count, 0u);
    TestNavigationDelegate *delegate = [[TestNavigationDelegate alloc] init];
    XCTestExpectation *htmlLoaded = [self expectationWithDescription:@"custom loading HTML rendered"];
    [delegate waitForDidFinishNavigation:htmlLoaded];
    loadingWebView.navigationDelegate = delegate;
    [self waitForExpectations:@[htmlLoaded] timeout:15];
    XCTestExpectation *contents = [self expectationWithDescription:@"custom overlay content and base URL"];
    [loadingWebView evaluateJavaScript:@"[document.title, new URL('logo.svg', document.baseURI).href, typeof cordova]" completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqualObjects(result, (@[@"App loading screen", @"https://assets.example/brand/logo.svg", @"undefined"]));
        [contents fulfill];
    }];
    [self waitForExpectations:@[contents] timeout:10];
    XCTAssertEqualObjects([controller valueForKey:@"loadCounter"], loadCount);
    [controller hideLoadingScreen];
    XCTAssertNil([controller valueForKey:@"backgroundView"]);
    XCTAssertNil(htmlOverlay.superview);

    // Legacy names now work without copying either old HTML resource into the app.
    [controller showNativeBackgroundView:@"loadingScreenStyle1" andStrokeColor:@"#007cd5"];
    UIView *legacyOverlay = [controller valueForKey:@"backgroundView"];
    XCTAssertTrue([legacyOverlay.subviews.firstObject isKindOfClass:UIActivityIndicatorView.class]);
    [controller hideLoadingScreen];
}

- (void)testMainAppSelectionPersistenceAndJSONHandoff
{
    NSString *key = [@"CDVTestSelection_" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSDictionary *apps = @{@"main": @{@"root": @"www", @"startPage": @"index.html"}, @"alternate": @{@"root": @"www", @"startPage": @"index.html?alternate=true"}};
    CDVViewController *controller = [self viewController];
    controller.webAppSelectionKey = key;
    XCTAssertTrue([controller configureWebApps:apps defaultAppID:@"main" error:nil]);
    XCTAssertEqualObjects(controller.activeWebAppID, @"main");
    XCTestExpectation *initial = [self expectationForNotification:CDVPageDidLoadNotification object:nil handler:^BOOL(NSNotification *note) { return note.object == controller.webView; }];
    [controller loadViewIfNeeded];
    [self waitForExpectations:@[initial] timeout:15];
    id oldDelegate = controller.commandDelegate;
    UIView *oldView = controller.webView;
    XCTestExpectation *replacement = [self expectationForNotification:CDVPageDidLoadNotification object:nil handler:^BOOL(NSNotification *note) { return note.object == controller.webView; }];
    XCTAssertTrue([controller switchToWebApp:@"alternate" remember:YES context:@{@"token": @"handoff"} error:nil]);
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:key]);
    [self waitForExpectations:@[replacement] timeout:15];
    XCTAssertNotEqual(controller.webView, oldView);
    XCTAssertNotEqual(controller.commandDelegate, oldDelegate);
    XCTestExpectation *context = [self expectationWithDescription:@"replacement context injected"];
    [controller.webViewEngine evaluateJavaScript:@"window.cordovaWebApp" completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqualObjects(result, (@{@"appId": @"alternate", @"context": @{@"token": @"handoff"}}));
        [context fulfill];
    }];
    [self waitForExpectations:@[context] timeout:10];
    [controller confirmWebAppReady];
    CDVViewController *cold = [self viewController];
    cold.webAppSelectionKey = key;
    XCTAssertTrue([cold configureWebApps:apps defaultAppID:@"main" error:nil]);
    XCTAssertEqualObjects(cold.activeWebAppID, @"alternate");
    XCTAssertNil(cold.webAppContext);
    XCTestExpectation *sessionSwitch = [self expectationForNotification:CDVPageDidLoadNotification object:nil handler:^BOOL(NSNotification *note) { return note.object == controller.webView; }];
    XCTAssertTrue([controller switchToWebApp:@"main" remember:NO context:nil error:nil]);
    [self waitForExpectations:@[sessionSwitch] timeout:15];
    [controller confirmWebAppReady];
    XCTAssertEqualObjects([NSUserDefaults.standardUserDefaults stringForKey:key], @"alternate");
    NSError *error;
    XCTAssertFalse([controller switchToWebApp:@"missing" remember:YES context:nil error:&error]);
    XCTAssertNotNil(error);
    [controller clearRememberedWebApp];
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:key]);
}

- (void)testMainTerminationPolicyAndInvalidHandoff
{
    CDVViewController *controller = [self viewController];
    __block NSUInteger terminations = 0;
    controller.webViewTerminationHandler = ^{ terminations++; };
    XCTAssertTrue([controller handleWebContentTermination]);
    controller.automaticWebViewRecoveryEnabled = NO;
    XCTAssertFalse([controller handleWebContentTermination]);
    XCTAssertEqual(terminations, 2u);
    XCTAssertTrue(([controller configureWebApps:@{@"main": @{@"root": @"www", @"startPage": @"index.html"}} defaultAppID:@"main" error:nil]));
    NSError *error = nil;
    XCTAssertFalse([controller switchToWebApp:@"main" remember:NO context:NSDate.date error:&error]);
    XCTAssertNotNil(error);
    XCTAssertFalse(controller.isViewLoaded);
}

- (void)testSecondaryChannelValidation
{
    CDVViewController *controller = [self viewController];
    controller.startPage = @"secondary-channel-validation-host.html";
    [controller loadViewIfNeeded];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    __block NSArray *state = nil;
    while ([deadline timeIntervalSinceNow] > 0) {
        XCTestExpectation *sample = [self expectationWithDescription:@"secondary channel result"];
        [controller.webViewEngine evaluateJavaScript:@"[document.title, document.getElementById('results')?.textContent || '']" completionHandler:^(id result, NSError *error) {
            if (!error && [result isKindOfClass:NSArray.class]) state = result;
            [sample fulfill];
        }];
        [self waitForExpectations:@[sample] timeout:3];
        if ([state.firstObject hasPrefix:@"PASS secondary channel"] || [state.firstObject hasPrefix:@"FAIL secondary channel"]) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    XCTAssertEqualObjects(state.firstObject, @"PASS secondary channel validation", @"%@", state.count > 1 ? state[1] : @"No test result");
}

- (void)testSecondaryStreamRateGate
{
    CDVSecondaryStreamRateGate *gate = [CDVSecondaryStreamRateGate new];
    XCTAssertTrue([gate reserveAtTime:1 rateHz:20]);
    [gate finishValid:YES];
    XCTAssertFalse([gate reserveAtTime:1 + 0.89 / 20 rateHz:20]);
    XCTAssertTrue([gate reserveAtTime:1 + 0.91 / 20 rateHz:20]);
    [gate finishValid:NO]; // An invalid accepted sample leaves the slot free.
    XCTAssertTrue([gate reserveAtTime:1 + 0.91 / 20 rateHz:20]);
    [gate finishValid:YES];

    gate = [CDVSecondaryStreamRateGate new];
    NSTimeInterval now = 1;
    NSUInteger accepted = 0;
    for (NSUInteger i = 0; i < 20; i++) {
        if ([gate reserveAtTime:now rateHz:20]) { accepted++; [gate finishValid:YES]; }
        now += (i % 2 ? 0.94 : 1.06) / 20;
    }
    XCTAssertEqual(accepted, 20U);

    gate = [CDVSecondaryStreamRateGate new]; now = 1; accepted = 0;
    for (NSUInteger i = 0; i < 40; i++) {
        if ([gate reserveAtTime:now rateHz:20]) { accepted++; [gate finishValid:YES]; }
        now += 0.5 / 20;
    }
    XCTAssertGreaterThanOrEqual(accepted, 19U);
    XCTAssertLessThanOrEqual(accepted, 21U);

    gate = [CDVSecondaryStreamRateGate new];
    __block NSUInteger concurrentAccepted = 0;
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = 0; i < 2; i++) {
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if ([gate reserveAtTime:1 rateHz:20]) {
                @synchronized (gate) { concurrentAccepted++; }
                [NSThread sleepForTimeInterval:0.01];
                [gate finishValid:YES];
            }
        });
    }
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0);
    XCTAssertEqual(concurrentAccepted, 1U);
}

- (void)testSecondaryNativeStreams
{
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeBurst"], 0);
    [CDVSecondaryWebViewStreams pushSample:@1 streamName:@"nativeBurst"];
    CDVViewController *controller = [self viewController];
    controller.startPage = @"secondary-streams-host.html";
    [controller loadViewIfNeeded];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    __block NSString *title = nil;
    while ([deadline timeIntervalSinceNow] > 0) {
        XCTestExpectation *sample = [self expectationWithDescription:@"stream readiness"];
        [controller.webViewEngine evaluateJavaScript:@"document.title" completionHandler:^(id result, NSError *error) { if (!error) title = result; [sample fulfill]; }];
        [self waitForExpectations:@[sample] timeout:3];
        if ([title hasPrefix:@"READY"] || [title hasPrefix:@"FAIL"]) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertEqualObjects(title, @"READY secondary streams");
    XCTAssertTrue([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
    XCTAssertTrue([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeRate"]);
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"missing"]);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"missing"], 0);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeRate"], 1);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeFast"], 30);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeBurst"], 60);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeBatchOnly"], 20);

    __block double backgroundRate = 0;
    XCTestExpectation *produced = [self expectationWithDescription:@"background producer"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        backgroundRate = [CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeFast"];
        [CDVSecondaryWebViewStreams pushSample:@{ @"value": @(NAN) } streamName:@"nativeBurst"];
        for (NSInteger i = 1; i <= 3; i++) [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeBurst"];
        for (NSInteger i = 0; i < 20; i++) [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeRate"];
        [produced fulfill];
    });
    [self waitForExpectations:@[produced] timeout:3];
    XCTAssertEqual(backgroundRate, 30);
    __block NSDictionary *state = nil;
    deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while ([deadline timeIntervalSinceNow] > 0) {
        XCTestExpectation *sample = [self expectationWithDescription:@"stream delivery"];
        [controller.webViewEngine evaluateJavaScript:@"window.streamState" completionHandler:^(id result, NSError *error) { if (!error && [result isKindOfClass:NSDictionary.class]) state = result; [sample fulfill]; }];
        [self waitForExpectations:@[sample] timeout:3];
        if (state[@"burst"] && [state[@"rateCount"] integerValue] > 0 && [state[@"channelErrors"] count] > 0) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertEqualObjects(state[@"burst"][@"latest"], @3);
    XCTAssertEqualObjects(state[@"burst"][@"batch"], (@[@1, @2, @3]));
    XCTAssertTrue([state[@"channelErrors"] containsObject:@"INVALID_JSON"]);
    NSUInteger errorsBeforeFast = [state[@"channelErrors"] count];
    [CDVSecondaryWebViewStreams pushSample:@1000 streamName:@"nativeFast"];
    [CDVSecondaryWebViewStreams pushSample:@{ @"value": @(NAN) } streamName:@"nativeFast"];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    XCTestExpectation *droppedInvalid = [self expectationWithDescription:@"throttled invalid sample"];
    [controller.webViewEngine evaluateJavaScript:@"window.streamState.channelErrors.length" completionHandler:^(id result, NSError *error) {
        if (!error) XCTAssertEqual([result unsignedIntegerValue], errorsBeforeFast);
        [droppedInvalid fulfill];
    }];
    [self waitForExpectations:@[droppedInvalid] timeout:3];
    [CDVSecondaryWebViewStreams pushSample:@{ @"value": @(NAN) } streamName:@"nativeFast"];
    deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([deadline timeIntervalSinceNow] > 0) {
        XCTestExpectation *sample = [self expectationWithDescription:@"accepted invalid sample"];
        [controller.webViewEngine evaluateJavaScript:@"window.streamState.channelErrors.length" completionHandler:^(id result, NSError *error) {
            if (!error && [result unsignedIntegerValue] > errorsBeforeFast) state = @{ @"invalidReported": @YES };
            [sample fulfill];
        }];
        [self waitForExpectations:@[sample] timeout:3];
        if (state[@"invalidReported"]) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertTrue([state[@"invalidReported"] boolValue]);
    [CDVSecondaryWebViewStreams pushSample:@2000 streamName:@"nativeFast"];
    deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([deadline timeIntervalSinceNow] > 0) {
        XCTestExpectation *sample = [self expectationWithDescription:@"valid sample after invalid"];
        [controller.webViewEngine evaluateJavaScript:@"window.streamState.fastValues" completionHandler:^(id result, NSError *error) {
            if (!error && [result isKindOfClass:NSArray.class]) state = @{ @"fastValues": result };
            [sample fulfill];
        }];
        [self waitForExpectations:@[sample] timeout:3];
        if ([state[@"fastValues"] containsObject:@2000]) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertTrue([state[@"fastValues"] containsObject:@2000]);
    NSUInteger fastBefore = [state[@"fastValues"] count];
    XCTestExpectation *fastProduced = [self expectationWithDescription:@"fast native producer"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSInteger i = 0; i < 50; i++) {
            [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeFast"];
            [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeBatchOnly"];
            [NSThread sleepForTimeInterval:0.002];
        }
        [fastProduced fulfill];
    });
    [self waitForExpectations:@[fastProduced] timeout:5];
    deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([deadline timeIntervalSinceNow] > 0) {
        XCTestExpectation *sample = [self expectationWithDescription:@"batch completion"];
        [controller.webViewEngine evaluateJavaScript:@"window.streamState" completionHandler:^(id result, NSError *error) {
            if (!error && [result isKindOfClass:NSDictionary.class]) state = result;
            [sample fulfill];
        }];
        [self waitForExpectations:@[sample] timeout:3];
        if ([state[@"batchValues"] count] == 50) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    NSMutableArray *expectedBatch = [NSMutableArray array];
    for (NSInteger i = 0; i < 50; i++) [expectedBatch addObject:@(i)];
    XCTAssertEqualObjects(state[@"batchValues"], expectedBatch);
    XCTAssertGreaterThan([state[@"fastValues"] count], fastBefore);
    XCTAssertLessThanOrEqual([state[@"fastValues"] count] - fastBefore, 8U);
    XCTestExpectation *paced = [self expectationWithDescription:@"paced native producer"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSInteger i = 0; i < 20; i++) {
            [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeJitter"];
            [NSThread sleepForTimeInterval:(i % 2 ? 0.047 : 0.053)];
        }
        for (NSInteger i = 0; i < 40; i++) {
            [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeHalf"];
            [NSThread sleepForTimeInterval:0.025];
        }
        [paced fulfill];
    });
    [self waitForExpectations:@[paced] timeout:5];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTestExpectation *pacedResult = [self expectationWithDescription:@"paced stream counts"];
    [controller.webViewEngine evaluateJavaScript:@"window.streamState" completionHandler:^(id result, NSError *error) {
        if (!error && [result isKindOfClass:NSDictionary.class]) state = result;
        [pacedResult fulfill];
    }];
    [self waitForExpectations:@[pacedResult] timeout:3];
    XCTAssertGreaterThanOrEqual([state[@"jitterValues"] count], 17U);
    XCTAssertLessThanOrEqual([state[@"halfValues"] count], 24U);
    XCTAssertGreaterThanOrEqual([state[@"halfValues"] count], 16U);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTestExpectation *rate = [self expectationWithDescription:@"rate cap"];
    [controller.webViewEngine evaluateJavaScript:@"window.streamState.rateCount" completionHandler:^(id result, NSError *error) { if (!error) XCTAssertEqual([result integerValue], 1); [rate fulfill]; }];
    [self waitForExpectations:@[rate] timeout:3];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeRate"]);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeFast"], 0);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeBatchOnly"], 0);
    [CDVSecondaryWebViewStreams pushSample:@4 streamName:@"nativeBurst"];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    XCTestExpectation *discarded = [self expectationWithDescription:@"unsubscribed push"];
    [controller.webViewEngine evaluateJavaScript:@"window.streamState.burst.latest" completionHandler:^(id result, NSError *error) { if (!error) XCTAssertEqualObjects(result, @3); [discarded fulfill]; }];
    [self waitForExpectations:@[discarded] timeout:3];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillEnterForegroundNotification object:nil];
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
    XCTestExpectation *destroyRequested = [self expectationWithDescription:@"secondary destroy requested"];
    [controller.webViewEngine evaluateJavaScript:@"window.streamDestroyDone = false; cordova.secondaryWebView.destroy().then(() => { window.streamDestroyDone = true; }); true" completionHandler:^(id result, NSError *error) {
        XCTAssertNil(error);
        [destroyRequested fulfill];
    }];
    [self waitForExpectations:@[destroyRequested] timeout:5];
    deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    __block BOOL destroyDone = NO;
    while ([deadline timeIntervalSinceNow] > 0 && !destroyDone) {
        XCTestExpectation *checked = [self expectationWithDescription:@"secondary destroy completion"];
        [controller.webViewEngine evaluateJavaScript:@"window.streamDestroyDone" completionHandler:^(id result, NSError *error) {
            if (!error) destroyDone = [result boolValue];
            [checked fulfill];
        }];
        [self waitForExpectations:@[checked] timeout:3];
        if (!destroyDone) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    XCTAssertTrue(destroyDone);
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeRate"]);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeBurst"], 0);
    XCTAssertEqual([CDVSecondaryWebViewStreams maximumRateHzForStream:@"nativeRate"], 0);
    [CDVSecondaryWebViewStreams pushSample:@5 streamName:@"nativeBurst"];
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
}

@end
