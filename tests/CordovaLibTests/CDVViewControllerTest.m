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
#import "CDVGameViewController.h"
#import "CDVViewController+Private.h"
#import <Cordova/CDVPlugin.h>
#import <Cordova/CDVPluginResult.h>
#import <Cordova/CDVInvokedUrlCommand.h>
#import <Cordova/CDVViewController.h>
#import <Cordova/CDVPluginNotifications.h>

@interface CDVHostTestPlugin : CDVPlugin
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, copy) NSString *lateCallback;
@end
@implementation CDVHostTestPlugin
- (void)echo:(CDVInvokedUrlCommand *)command {
    self.count++;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"count": @(self.count), @"value": command.arguments.firstObject ?: NSNull.null}] callbackId:command.callbackId];
}
- (void)stream:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *first = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:1];
    [first setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:first callbackId:command.callbackId];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:2] callbackId:command.callbackId];
}
- (void)delayed:(CDVInvokedUrlCommand *)command { self.lateCallback = command.callbackId; }
@end

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

- (void)testCloneInheritsRootWithoutLoadingAndCanBeRecreated
{
    if (@available(iOS 14.0, *)) {
        CDVViewController *parent = [self viewController];
        parent.webContentFolderName = @"alternate-www";
        parent.startPage = @"home.html?source=parent";
        parent.configFile = @"config-custom.xml";
        XCTAssertTrue([parent createWebViewClone]);
        CDVGameViewController *clone = (CDVGameViewController *)parent.childViewControllers.firstObject;
        XCTAssertEqualObjects(clone.webContentFolderName, parent.webContentFolderName);
        XCTAssertEqualObjects(clone.startPage, parent.startPage);
        XCTAssertFalse([clone isKindOfClass:CDVViewController.class]);
        parent.webContentFolderName = @"changed-www";
        XCTAssertEqualObjects(clone.webContentFolderName, @"alternate-www");
        XCTAssertFalse([parent createWebViewClone]);
        XCTAssertTrue([parent dismissWebViewClone]);
        XCTAssertFalse(clone.isViewLoaded);
        XCTAssertEqual(parent.childViewControllers.count, 0u);
        XCTAssertTrue([parent createWebViewCloneWithWebContentFolderName:@"clone-www" startPage:@"clone.html"]);
        XCTAssertTrue([parent dismissWebViewClone]);
    }
}

- (void)testIndependentRootsLoadAssetsAndSwitchWithoutReloading
{
    if (@available(iOS 14.0, *)) {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *mainRoot = [directory stringByAppendingPathComponent:@"main app"];
        NSString *cloneRoot = [directory stringByAppendingPathComponent:@"clone app"];
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *root in @[mainRoot, cloneRoot]) {
            XCTAssertTrue([manager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
            NSString *html = @"<!doctype html><script src='identity.js'></script><body>Root test</body>";
            XCTAssertTrue([html writeToFile:[root stringByAppendingPathComponent:@"index.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
            NSString *script = [root isEqualToString:mainRoot] ? @"window.identity = 'parent';" : @"window.identity = 'clone'; window.host.ready();";
            XCTAssertTrue([script writeToFile:[root stringByAppendingPathComponent:@"identity.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        }

        CDVViewController *parent = [self viewController];
        parent.webContentFolderName = mainRoot;
        parent.startPage = @"index.html?root=main#home";
        XCTestExpectation *loaded = [self expectationForNotification:CDVPageDidLoadNotification object:nil handler:^BOOL(NSNotification *note) {
            return note.object == parent.webView;
        }];
        [parent loadViewIfNeeded];
        [self waitForExpectations:@[loaded] timeout:15];
        NSNumber *parentLoadCount = [parent valueForKey:@"loadCounter"];
        CDVHostTestPlugin *plugin = [[CDVHostTestPlugin alloc] init];
        [parent registerPlugin:plugin withPluginName:@"HostTest"];
        NSUInteger pluginCount = parent.enumerablePlugins.count;

        // Exercise file URLs as well as absolute paths, including spaces in both roots.
        XCTAssertTrue([parent createWebViewCloneWithWebContentFolderName:[NSURL fileURLWithPath:cloneRoot isDirectory:YES].absoluteString startPage:@"index.html?root=clone"]);
        XCTestExpectation *ready = [self expectationWithDescription:@"clone bridge ready"];
        [parent showWebViewCloneWithLoadingScreenHTML:@"<html><body>Preparing training</body></html>" baseURL:nil completionHandler:^(BOOL success) {
            XCTAssertTrue(success);
            [ready fulfill];
        }];
        XCTAssertNotNil([parent valueForKey:@"backgroundView"]);
        [parent showSplashScreen:NO];
        XCTAssertNotNil([parent valueForKey:@"backgroundView"]);
        [self waitForExpectations:@[ready] timeout:15];
        XCTAssertNil([parent valueForKey:@"backgroundView"]);
        CDVGameViewController *clone = (CDVGameViewController *)parent.childViewControllers.firstObject;
        XCTAssertEqualObjects([parent valueForKey:@"loadCounter"], parentLoadCount);

        XCTestExpectation *parentIdentity = [self expectationWithDescription:@"parent asset"];
        [parent.webViewEngine evaluateJavaScript:@"window.identity" completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqualObjects(result, @"parent");
            [parentIdentity fulfill];
        }];
        XCTestExpectation *cloneIdentity = [self expectationWithDescription:@"clone asset"];
        [clone.webView evaluateJavaScript:@"window.identity + ':' + window.__$cognifit$__isWebViewClone" completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqualObjects(result, @"clone:true");
            [cloneIdentity fulfill];
        }];
        [self waitForExpectations:@[parentIdentity, cloneIdentity] timeout:10];
        XCTAssertEqualObjects(parent.webViewEngine.URL.query, @"root=main");
        XCTAssertEqualObjects(parent.webViewEngine.URL.fragment, @"home");
        XCTAssertEqualObjects(clone.webView.URL.query, @"root=clone");
        XCTestExpectation *asyncReply = [self expectationWithDescription:@"async parent bridge"];
        WKWebView *cloneWKWebView = (WKWebView *)clone.webView;
        [cloneWKWebView callAsyncJavaScript:@"return await window.webkit.messageHandlers.webViewParent.postMessage({title:'CALL_ASYNC', script:'return window.identity;'});" arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqualObjects(result, @"parent");
            [asyncReply fulfill];
        }];
        XCTestExpectation *invalidReply = [self expectationWithDescription:@"invalid bridge message rejects"];
        [cloneWKWebView callAsyncJavaScript:@"try { await window.webkit.messageHandlers.webViewParent.postMessage({title:42}); return false; } catch (error) { return true; }" arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqualObjects(result, @YES);
            [invalidReply fulfill];
        }];
        XCTestExpectation *taskFinished = [self expectationWithDescription:@"clone task completion"];
        [parent loadTaskInWebViewCloneWithJsCommand:@"window.webkit.messageHandlers.webViewParent.postMessage({title:'TRAINING_TASK_FINISHED', identity:window.identity});" withCompletionHandler:^(NSDictionary *body) {
            XCTAssertEqualObjects(body[@"identity"], @"clone");
            [taskFinished fulfill];
        }];
        [self waitForExpectations:@[asyncReply, invalidReply, taskFinished] timeout:10];
        XCTestExpectation *hostCalls = [self expectationWithDescription:@"vanilla host routes to main plugin instance"];
        [clone.webView callAsyncJavaScript:@"const plugins = await host.getLoadedPlugins(); const a = await host.callPlugin('HostTest','echo',['one']); const b = await host.callPlugin('HostTest','echo',['two']); const stream = await new Promise((resolve,reject) => { const values=[]; host.subscribePlugin('HostTest','stream',[],value => { values.push(value); if(values.length===2) resolve(values); },reject); }); let invalid=false; try { await host.callPlugin('HostTest','missing',[]); } catch(e) { invalid=true; } let timedOut=false; try { await host.callPlugin('HostTest','delayed',[],20); } catch(e) { timedOut=e.code==='TIMEOUT'; } return [typeof cordova, plugins.some(p => p.className==='CDVHostTestPlugin'), a.count,b.count,stream,invalid,timedOut];" arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqualObjects(result, (@[@"undefined", @YES, @1, @2, @[@1,@2], @YES, @YES]));
            [hostCalls fulfill];
        }];
        [self waitForExpectations:@[hostCalls] timeout:15];
        XCTAssertEqual(plugin.count, 2);
        XCTAssertEqual(parent.enumerablePlugins.count, pluginCount);
        XCTAssertEqual(clone.requests.count, 0u);

        XCTestExpectation *messageToMain = [self expectationWithDescription:@"game to main JSON"];
        parent.cloneEventHandler = ^(NSDictionary *event) {
            if ([event[@"type"] isEqual:@"message"]) {
                XCTAssertEqualObjects(event[@"detail"], (@{@"score": @42}));
                [messageToMain fulfill];
            }
        };
        [clone.webView evaluateJavaScript:@"host.onmessage = value => host.postMessage(value);" completionHandler:nil];
        [parent postMessageToWebViewClone:@{@"score": @42} completionHandler:nil];
        [self waitForExpectations:@[messageToMain] timeout:10];
        __block BOOL terminated = NO;
        parent.cloneEventHandler = ^(NSDictionary *event) { terminated = [event[@"type"] isEqual:@"terminated"]; };
        [clone webViewWebContentProcessDidTerminate:clone.webView];
        XCTAssertTrue(terminated);
        XCTAssertFalse(clone.cloneReady);
        // The package reports termination without choosing a recovery action.
        XCTAssertNotNil(clone.webView);
        clone.cloneReady = YES;
        UIView *cloneWebView = clone.webView;
        XCTAssertTrue([parent hideWebViewClone]);
        XCTAssertTrue(clone.view.hidden);
        __block BOOL shownAgain = NO;
        [parent showWebViewClone:^(BOOL success) { shownAgain = success; }];
        XCTAssertTrue(shownAgain);
        XCTAssertFalse(clone.view.hidden);
        XCTAssertEqual(clone.webView, cloneWebView);
        XCTAssertTrue([parent dismissWebViewClone]);
        XCTAssertNil(clone.webView);
        XCTAssertTrue([parent createWebViewCloneWithWebContentFolderName:cloneRoot startPage:@"index.html"]);
        CDVGameViewController *newClone = (CDVGameViewController *)parent.childViewControllers.firstObject;
        newClone.requests[@"1"] = @NO;
        [plugin.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"late"] callbackId:plugin.lateCallback];
        XCTestExpectation *lateDrained = [self expectationWithDescription:@"late plugin result discarded"];
        dispatch_async(dispatch_get_main_queue(), ^{
            XCTAssertEqual(newClone.requests.count, 1u);
            [lateDrained fulfill];
        });
        [self waitForExpectations:@[lateDrained] timeout:5];
        XCTAssertTrue([parent dismissWebViewClone]);

        UIView *oldWebView = parent.webView;
        XCTestExpectation *reloaded = [self expectationForNotification:CDVPageDidLoadNotification object:nil handler:^BOOL(NSNotification *note) {
            return note.object == parent.webView;
        }];
        [parent reloadAppWithLoadingScreenHTML:nil baseURL:nil];
        XCTAssertNotNil([parent valueForKey:@"backgroundView"]);
        [self waitForExpectations:@[reloaded] timeout:15];
        XCTAssertNotEqual(parent.webView, oldWebView);
        XCTAssertNil([parent valueForKey:@"backgroundView"]);
        XCTAssertEqualObjects(parent.webContentFolderName, mainRoot);
        XCTAssertEqualObjects([parent valueForKey:@"loadCounter"], @1);
        XCTAssertTrue([manager removeItemAtPath:directory error:nil]);
    }
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

@end

