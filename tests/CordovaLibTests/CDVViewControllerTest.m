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
#import <Cordova/CDVViewController.h>
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

- (void)testCloneInheritsRootWithoutLoadingAndCanBeRecreated
{
    if (@available(iOS 14.0, *)) {
        CDVViewController *parent = [self viewController];
        parent.webContentFolderName = @"alternate-www";
        parent.startPage = @"home.html?source=parent";
        parent.configFile = @"config-custom.xml";
        XCTAssertTrue([parent createWebViewClone]);
        CDVViewController *clone = (CDVViewController *)parent.childViewControllers.firstObject;
        XCTAssertEqualObjects(clone.webContentFolderName, parent.webContentFolderName);
        XCTAssertEqualObjects(clone.startPage, parent.startPage);
        XCTAssertEqualObjects(clone.configFile, parent.configFile);
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
            NSString *script = [root isEqualToString:mainRoot] ? @"window.identity = 'parent';" : @"window.identity = 'clone'; window.webkit.messageHandlers.webViewParent.postMessage({title:'UP_AND_RUNNING'});";
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

        // Exercise file URLs as well as absolute paths, including spaces in both roots.
        XCTAssertTrue([parent createWebViewCloneWithWebContentFolderName:[NSURL fileURLWithPath:cloneRoot isDirectory:YES].absoluteString startPage:@"index.html?root=clone"]);
        XCTestExpectation *ready = [self expectationWithDescription:@"clone bridge ready"];
        [parent showWebViewClone:^(BOOL success) {
            XCTAssertTrue(success);
            [ready fulfill];
        }];
        [self waitForExpectations:@[ready] timeout:15];
        CDVViewController *clone = (CDVViewController *)parent.childViewControllers.firstObject;
        XCTAssertEqualObjects([parent valueForKey:@"loadCounter"], parentLoadCount);

        XCTestExpectation *parentIdentity = [self expectationWithDescription:@"parent asset"];
        [parent.webViewEngine evaluateJavaScript:@"window.identity" completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqualObjects(result, @"parent");
            [parentIdentity fulfill];
        }];
        XCTestExpectation *cloneIdentity = [self expectationWithDescription:@"clone asset"];
        [clone.webViewEngine evaluateJavaScript:@"window.identity + ':' + window.__$cognifit$__isWebViewClone" completionHandler:^(id result, NSError *error) {
            XCTAssertNil(error);
            XCTAssertEqualObjects(result, @"clone:true");
            [cloneIdentity fulfill];
        }];
        [self waitForExpectations:@[parentIdentity, cloneIdentity] timeout:10];
        XCTAssertEqualObjects(parent.webViewEngine.URL.query, @"root=main");
        XCTAssertEqualObjects(parent.webViewEngine.URL.fragment, @"home");
        XCTAssertEqualObjects(clone.webViewEngine.URL.query, @"root=clone");
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
        UIView *cloneWebView = clone.webView;
        XCTAssertTrue([parent hideWebViewClone]);
        XCTAssertTrue(clone.view.hidden);
        __block BOOL shownAgain = NO;
        [parent showWebViewClone:^(BOOL success) { shownAgain = success; }];
        XCTAssertTrue(shownAgain);
        XCTAssertFalse(clone.view.hidden);
        XCTAssertEqual(clone.webView, cloneWebView);
        XCTAssertTrue([parent dismissWebViewClone]);

        UIView *oldWebView = parent.webView;
        XCTestExpectation *reloaded = [self expectationForNotification:CDVPageDidLoadNotification object:nil handler:^BOOL(NSNotification *note) {
            return note.object == parent.webView;
        }];
        [parent reloadAppWithBackgroundStyle:@"nil" andStrokeColor:nil];
        [self waitForExpectations:@[reloaded] timeout:15];
        XCTAssertNotEqual(parent.webView, oldWebView);
        XCTAssertEqualObjects(parent.webContentFolderName, mainRoot);
        XCTAssertEqualObjects([parent valueForKey:@"loadCounter"], @1);
        XCTAssertTrue([manager removeItemAtPath:directory error:nil]);
    }
}

@end

