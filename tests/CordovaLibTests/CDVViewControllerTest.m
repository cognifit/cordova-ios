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

@interface CDVViewControllerTest : XCTestCase

@end

@interface CDVViewController ()

// expose private interface
- (bool)checkAndReinitViewUrl;
- (bool)isUrlEmpty:(NSURL*)url;

@end

@implementation CDVViewControllerTest

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

- (void)testSecondaryNativeStreams
{
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
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

    XCTestExpectation *produced = [self expectationWithDescription:@"background producer"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [CDVSecondaryWebViewStreams pushSample:@{ @"value": @(NAN) } streamName:@"nativeBurst"];
        for (NSInteger i = 1; i <= 3; i++) [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeBurst"];
        for (NSInteger i = 0; i < 20; i++) [CDVSecondaryWebViewStreams pushSample:@(i) streamName:@"nativeRate"];
        [produced fulfill];
    });
    [self waitForExpectations:@[produced] timeout:3];
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
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTestExpectation *rate = [self expectationWithDescription:@"rate cap"];
    [controller.webViewEngine evaluateJavaScript:@"window.streamState.rateCount" completionHandler:^(id result, NSError *error) { if (!error) XCTAssertEqual([result integerValue], 1); [rate fulfill]; }];
    [self waitForExpectations:@[rate] timeout:3];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeRate"]);
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
    [CDVSecondaryWebViewStreams pushSample:@5 streamName:@"nativeBurst"];
    XCTAssertFalse([CDVSecondaryWebViewStreams hasSubscriberForStream:@"nativeBurst"]);
}

@end
