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

#import <TargetConditionals.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#import <Cordova/CDVAppDelegate.h>
#import <Cordova/CDVPlugin.h>
#import "CDVPlugin+Private.h"
#import <Cordova/CDVConfigParser.h>
#import <Cordova/CDVSettingsDictionary.h>
#import <Cordova/CDVTimer.h>
#import "CDVCommandDelegateImpl.h"
#import "CDVViewController+Private.h"

static UIColor *defaultBackgroundColor(void) {
    return UIColor.systemBackgroundColor;
}

/** Flag to know if the App is "cold booting" or not. This value is passed to the web App. */
static BOOL IS_COLD_BOOT = YES;

API_AVAILABLE(ios(14.0))
@interface CloneMessageHandler : NSObject<WKScriptMessageHandlerWithReply>

@property (nonatomic, weak, readonly) CDVViewController* viewController;

- (instancetype)initWithViewController:(CDVViewController*)viewController;

@end

API_AVAILABLE(ios(14.0))
@interface WebViewWeakScriptMessageHandler : NSObject <WKScriptMessageHandlerWithReply>

@property (nonatomic, weak, readonly) id<WKScriptMessageHandlerWithReply>scriptMessageHandler;

- (instancetype)initWithScriptMessageHandler:(id<WKScriptMessageHandlerWithReply>)scriptMessageHandler;

@end

@interface CDVViewController () <CDVWebViewEngineConfigurationDelegate, UIScrollViewDelegate> {
    id <CDVWebViewEngineProtocol> _webViewEngine;
    id <CDVCommandDelegate> _commandDelegate;
    NSMutableDictionary<NSString *, CDVPlugin *> *_pluginObjects;
    NSMutableDictionary<NSString *, NSString *> *_pluginsMap;
    CDVCommandQueue* _commandQueue;
    UIColor *_backgroundColor;
    UIColor *_splashBackgroundColor;
    UIColor *_statusBarBackgroundColor;
    UIColor *_statusBarWebViewColor;
    UIColor *_statusBarDefaultColor;
    CDVSettingsDictionary* _settings;
}

@property (nonatomic, readwrite, strong) NSMutableArray* startupPluginNames;
@property (nonatomic, readwrite, strong) UIView *launchView;
@property (nonatomic, readwrite, strong) UIView *statusBar;
@property (nonatomic, readwrite, strong) UIView* backgroundView;
@property (nonatomic, assign) BOOL loadingScreenForClone;

@property (readwrite, assign) NSInteger loadCounter;

@property (nonatomic, readwrite, strong) CDVViewController* clone;
@property (readwrite, assign) BOOL isClone;
@property (readwrite, assign) BOOL cloneReady;
@property (readwrite, assign) BOOL clonePresentationRequested;
@property (nonatomic, readwrite, strong) id<WKScriptMessageHandlerWithReply> cloneMessageHandler;
@property (nonatomic, readwrite, copy) VoidCompletionHandler showWebViewCloneCompletionHandler;
@property (nonatomic, readwrite, copy) TaskCompletionHandler loadTaskInWebViewCloneCompletionHandler;
@property (nonatomic, readwrite, weak) CDVViewController* cloneParent;

@property (readwrite, assign) BOOL initialized;

@end

@implementation CDVViewController

@synthesize pluginObjects = _pluginObjects;
@synthesize pluginsMap = _pluginsMap;
@synthesize commandDelegate = _commandDelegate;
@synthesize commandQueue = _commandQueue;
@synthesize webViewEngine = _webViewEngine;
@synthesize backgroundColor = _backgroundColor;
@synthesize splashBackgroundColor = _splashBackgroundColor;
@synthesize statusBarBackgroundColor = _statusBarBackgroundColor;
@synthesize settings = _settings;
@dynamic webView;
@dynamic enumerablePlugins;

#pragma mark - Initializers

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self != nil) {
        [self _cdv_init];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self != nil) {
        [self _cdv_init];
    }
    return self;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        [self _cdv_init];
    }
    return self;
}

- (void)_cdv_init
{
    if (!self.initialized) {
        _commandQueue = [[CDVCommandQueue alloc] initWithViewController:self];
        _commandDelegate = [[CDVCommandDelegateImpl alloc] initWithViewController:self];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppWillTerminate:)
                                                     name:UIApplicationWillTerminateNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onAppDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onWebViewPageDidLoad:)
                                                     name:CDVPageDidLoadNotification object:nil];

        // Default property values
        self.configFile = @"config.xml";
        self.webContentFolderName = @"www";
        self.showInitialSplashScreen = YES;

        // Initialize the plugin objects dict.
        _pluginObjects = [[NSMutableDictionary alloc] initWithCapacity:20];

        // Prevent reinitializing
        self.initialized = YES;
    }
}

#pragma mark -

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_commandQueue dispose];

    [self.webViewEngine loadHTMLString:@"about:blank" baseURL:nil];

    @synchronized(_pluginObjects) {
        [[_pluginObjects allValues] makeObjectsPerformSelector:@selector(dispose)];
        [_pluginObjects removeAllObjects];
    }

    [self.webView removeFromSuperview];
    [self.launchView removeFromSuperview];

    _webViewEngine = nil;
}

#pragma mark - Getters & Setters

- (NSArray <CDVPlugin *> *)enumerablePlugins
{
    @synchronized(_pluginObjects) {
        return [_pluginObjects allValues];
    }
}

- (NSString *)wwwFolderName
{
    return self.webContentFolderName;
}

- (void)setWwwFolderName:(NSString *)name
{
    self.webContentFolderName = name;
}

- (void)setBackgroundColor:(UIColor *)color
{
    _backgroundColor = color ?: defaultBackgroundColor();

    [self.webView setBackgroundColor:self.backgroundColor];
}

- (void)setSplashBackgroundColor:(UIColor *)color
{
    _splashBackgroundColor = color ?: self.backgroundColor;

    [self.launchView setBackgroundColor:self.splashBackgroundColor];
}

- (UIColor *)statusBarBackgroundColor
{
    // If a status bar background color has been explicitly set using the JS API, we always use that.
    // Otherwise, if the webview reports a themeColor meta tag (iOS 15.4+) we use that.
    // Otherwise, we use the status bar background color provided in IB (from config.xml).
    // Otherwise, we use the background color.
    return _statusBarBackgroundColor ?: _statusBarWebViewColor ?: _statusBarDefaultColor ?: self.backgroundColor;
}

- (void)setStatusBarBackgroundColor:(UIColor *)color
{
    // We want the initial value from IB to set the statusBarDefaultColor and
    // then all future changes to set the statusBarBackgroundColor.
    //
    // The reason for this is that statusBarBackgroundColor is treated like a
    // forced override when it is set, and we don't want that for the initial
    // value from config.xml set via IB.

    if (!_statusBarBackgroundColor && !_statusBarWebViewColor && !_statusBarDefaultColor) {
        _statusBarDefaultColor = color;
    } else {
        _statusBarBackgroundColor = color;
    }

    [self.statusBar setBackgroundColor:self.statusBarBackgroundColor];
}

- (void)setStatusBarWebViewColor:(UIColor *)color
{
    _statusBarWebViewColor = color;

    [self.statusBar setBackgroundColor:self.statusBarBackgroundColor];
}

// Only for testing
- (void)setSettings:(CDVSettingsDictionary *)settings
{
    _settings = settings;
}

- (nullable NSURL *)configFilePath
{
    NSString* path = self.configFile;

    // if path is relative, resolve it against the main bundle
    if (![path isAbsolutePath]) {
        NSString* absolutePath = [[NSBundle mainBundle] pathForResource:path ofType:nil];
        if(!absolutePath){
            NSAssert(NO, @"ERROR: %@ not found in the main bundle!", path);
        }
        path = absolutePath;
    }

    // Assert file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSAssert(NO, @"ERROR: %@ does not exist.", path);
        return nil;
    }

    return [NSURL fileURLWithPath:path];
}

- (NSURL *)webContentURL
{
    NSString *folder = self.webContentFolderName;
    if ([folder hasPrefix:@"file://"]) {
        return [NSURL URLWithString:folder].URLByStandardizingPath;
    }
    if (folder.isAbsolutePath) {
        return [NSURL fileURLWithPath:folder isDirectory:YES].URLByStandardizingPath;
    }
    return [[NSBundle mainBundle] URLForResource:folder withExtension:nil];
}

- (NSURL *)appUrl
{
    NSURL* appURL = nil;

    if ([self.startPage rangeOfString:@"://"].location != NSNotFound) {
        appURL = [NSURL URLWithString:self.startPage];
    } else if ([self.webContentFolderName rangeOfString:@"://"].location != NSNotFound && ![self.webContentFolderName hasPrefix:@"file://"]) {
        appURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", self.webContentFolderName, self.startPage]];
    } else if([self.webContentFolderName rangeOfString:@".bundle"].location != NSNotFound){
        // www folder is actually a bundle
        NSBundle* bundle = [NSBundle bundleWithPath:self.webContentFolderName];
        appURL = [bundle URLForResource:self.startPage withExtension:nil];
    } else if([self.webContentFolderName rangeOfString:@".framework"].location != NSNotFound){
        // www folder is actually a framework
        NSBundle* bundle = [NSBundle bundleWithPath:self.webContentFolderName];
        appURL = [bundle URLForResource:self.startPage withExtension:nil];
    } else {
        // CB-3005 strip parameters from start page to check if page exists in resources
        NSURL* startURL = [NSURL URLWithString:self.startPage];
        NSString* startFilePath = [self.commandDelegate pathForResource:[startURL path]];

        if (startFilePath == nil) {
            appURL = nil;
        } else {
            appURL = [NSURL fileURLWithPath:startFilePath];
            // CB-3005 Add on the query params or fragment.
            NSString* startPageNoParentDirs = self.startPage;
            NSRange r = [startPageNoParentDirs rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"] options:0];
            if (r.location != NSNotFound) {
                NSString* queryAndOrFragment = [self.startPage substringFromIndex:r.location];
                appURL = [NSURL URLWithString:queryAndOrFragment relativeToURL:appURL];
            }
        }
    }

    return appURL;
}

- (nullable NSURL *)errorURL
{
    NSString *setting = [self.settings cordovaSettingForKey:@"ErrorUrl"];
    if (setting == nil) {
        return nil;
    }

    if ([setting rangeOfString:@"://"].location != NSNotFound) {
        return [NSURL URLWithString:setting];
    } else {
        NSURL *url = [NSURL URLWithString:setting];
        NSString *errorFilePath = [self.commandDelegate pathForResource:[url path]];
        if (errorFilePath) {
            return [NSURL fileURLWithPath:errorFilePath];
        }
    }

    return nil;
}

- (nullable UIView *)webView
{
    if (_webViewEngine != nil) {
        return _webViewEngine.engineWebView;
    }

    return nil;
}

- (nullable NSString *)appURLScheme
{
    NSString* URLScheme = nil;

    NSArray* URLTypes = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleURLTypes"];

    if (URLTypes != nil) {
        NSDictionary* dict = [URLTypes objectAtIndex:0];
        if (dict != nil) {
            NSArray* URLSchemes = [dict objectForKey:@"CFBundleURLSchemes"];
            if (URLSchemes != nil) {
                URLScheme = [URLSchemes objectAtIndex:0];
            }
        }
    }

    return URLScheme;
}

#pragma mark - UIViewController & App Lifecycle

// Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
- (void)viewDidLoad
{
    [super viewDidLoad];

    // TODO: Remove in Cordova iOS 9
    if ([UIApplication.sharedApplication.delegate isKindOfClass:[CDVAppDelegate class]]) {
        CDVAppDelegate *appDelegate = (CDVAppDelegate *)UIApplication.sharedApplication.delegate;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (appDelegate.viewController == nil) {
            appDelegate.viewController = self;
        }
#pragma clang diagnostic pop
    }

    // Load settings
    [self loadSettings];

    // Instantiate the Launch screen
    if (!self.launchView) {
        [self createLaunchView];
    }

    // Instantiate the WebView
    if (!self.webView) {
        [self createGapView];
    }

    // Instantiate the status bar
    if (!self.statusBar) {
        [self createStatusBarView];
    }

    // /////////////////

    if ([self.startupPluginNames count] > 0) {
        [CDVTimer start:@"TotalPluginStartup"];

        for (NSString* pluginName in self.startupPluginNames) {
            [CDVTimer start:pluginName];
            [self getCommandInstance:pluginName];
            [CDVTimer stop:pluginName];
        }

        [CDVTimer stop:@"TotalPluginStartup"];
    }

    [self loadStartPage];

    [self.webView setBackgroundColor:self.backgroundColor];
    [self.launchView setBackgroundColor:self.splashBackgroundColor];
    [self.statusBar setBackgroundColor:self.statusBarBackgroundColor];

    if (self.showInitialSplashScreen) {
        [self.launchView setAlpha:1];
    }
}

-(void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillAppearNotification object:nil]];
}

-(void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

#if defined(TARGET_OS_MACCATALYST) && TARGET_OS_MACCATALYST
    BOOL hideTitlebar = [self.settings cordovaBoolSettingForKey:@"HideDesktopTitlebar" defaultValue:NO];
    if (hideTitlebar) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (scene) {
            scene.titlebar.titleVisibility = UITitlebarTitleVisibilityHidden;
            scene.titlebar.toolbar = nil;
        }
    } else {
        // We need to fix the web content going behind the title bar
        self.webView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.webView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor].active = YES;
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = YES;

        if ([self.webView respondsToSelector:@selector(scrollView)]) {
            UIScrollView *scrollView = [self.webView performSelector:@selector(scrollView)];
            scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
    }
#endif

    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewDidAppearNotification object:nil]];
}

-(void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillDisappearNotification object:nil]];
}

-(void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewDidDisappearNotification object:nil]];
}

-(void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillLayoutSubviewsNotification object:nil]];
}

-(void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewDidLayoutSubviewsNotification object:nil]];
}

-(void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id <UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVViewWillTransitionToSizeNotification object:[NSValue valueWithCGSize:size]]];
}

/*
 This method lets your application know that it is about to be terminated and purged from memory entirely
 */
- (void)onAppWillTerminate:(NSNotification *)notification
{
    // empty the tmp directory
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSError* __autoreleasing err = nil;

    // clear contents of NSTemporaryDirectory
    NSString* tempDirectoryPath = NSTemporaryDirectory();
    NSDirectoryEnumerator* directoryEnumerator = [fileMgr enumeratorAtPath:tempDirectoryPath];
    NSString* fileName = nil;
    BOOL result;

    while ((fileName = [directoryEnumerator nextObject])) {
        NSString* filePath = [tempDirectoryPath stringByAppendingPathComponent:fileName];
        result = [fileMgr removeItemAtPath:filePath error:&err];
        if (!result && err) {
            NSLog(@"Failed to delete: %@ (error: %@)", filePath, err);
        }
    }
}

/*
 This method is called to let your application know that it is about to move from the active to inactive state.
 You should use this method to pause ongoing tasks, disable timer, ...
 */
- (void)onAppWillResignActive:(NSNotification *)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationWillResignActive");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('resign');" scheduledOnRunLoop:NO];
}

/*
 In iOS 4.0 and later, this method is called instead of the applicationWillTerminate: method
 when the user quits an application that supports background execution.
 */
- (void)onAppDidEnterBackground:(NSNotification *)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationDidEnterBackground");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('pause', null, true);" scheduledOnRunLoop:NO];
}

/*
 In iOS 4.0 and later, this method is called as part of the transition from the background to the inactive state.
 You can use this method to undo many of the changes you made to your application upon entering the background.
 invariably followed by applicationDidBecomeActive
 */
- (void)onAppWillEnterForeground:(NSNotification *)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationWillEnterForeground");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('resume');"];
}

// This method is called to let your application know that it moved from the inactive to active state.
- (void)onAppDidBecomeActive:(NSNotification *)notification
{
    [self checkAndReinitViewUrl];
    // NSLog(@"%@",@"applicationDidBecomeActive");
    [self.commandDelegate evalJs:@"cordova.fireDocumentEvent('active');"];
}

- (void)didReceiveMemoryWarning
{
    BOOL doPurge = YES;

    // iterate through all the plugin objects, and call hasPendingOperation
    // if at least one has a pending operation, we don't call [super didReceiveMemoryWarning]
    for (CDVPlugin *plugin in self.enumerablePlugins) {
        if (plugin.hasPendingOperation) {
            NSLog(@"Plugin '%@' has a pending operation, memory purge is delayed for didReceiveMemoryWarning.", NSStringFromClass([plugin class]));
            doPurge = NO;
        }
    }

    if (doPurge) {
        // Releases the view if it doesn't have a superview.
        [super didReceiveMemoryWarning];
    }

    // Release any cached data, images, etc. that aren't in use.
}

/**
 Show the webview and fade out the intermediary view
 This is to prevent the flashing of the mainViewController
 */
- (void)onWebViewPageDidLoad:(NSNotification*)notification
{
    if (notification.object != self.webView) {
        return;
    }
    self.loadCounter += 1;
    [self.webViewEngine evaluateJavaScript:[NSString stringWithFormat:@"window.ionicWebViewLoadCounter = %li; window.ionicIsColdBoot = %s;", (long)self.loadCounter, IS_COLD_BOOT ? "true" : "false"] completionHandler:nil];
    IS_COLD_BOOT = NO;
    self.webView.hidden = NO;

    if ([self.webView respondsToSelector:@selector(scrollView)]) {
        UIScrollView *scrollView = [self.webView performSelector:@selector(scrollView)];
        [self scrollViewDidChangeAdjustedContentInset:scrollView];
    }

    if ([self.settings cordovaBoolSettingForKey:@"AutoHideSplashScreen" defaultValue:YES]) {
        CGFloat splashScreenDelaySetting = [self.settings cordovaFloatSettingForKey:@"SplashScreenDelay" defaultValue:0];

        if (splashScreenDelaySetting == 0) {
            [self showSplashScreen:NO];
        } else {
            // Divide by 1000 because config returns milliseconds and NSTimer takes seconds
            CGFloat splashScreenDelay = splashScreenDelaySetting / 1000;

            [NSTimer scheduledTimerWithTimeInterval:splashScreenDelay repeats:NO block:^(NSTimer * _Nonnull timer) {
                [self showSplashScreen:NO];
            }];
        }
    }
}

- (void)scrollViewDidChangeAdjustedContentInset:(UIScrollView *)scrollView
{
#if !defined(TARGET_OS_VISION) || !TARGET_OS_VISION
    if (self.webView.hidden) {
        self.statusBar.hidden = true;
        return;
    }

    self.statusBar.hidden = (scrollView.contentInsetAdjustmentBehavior == UIScrollViewContentInsetAdjustmentNever);
#endif
}

#if !defined(TARGET_OS_VISION) || !TARGET_OS_VISION
- (BOOL)prefersStatusBarHidden
{
    // The CDVStatusBar plugin overrides this in a category extension, and
    // should bypass this implementation entirely
    return self.statusBar.alpha < 0.0001f;
}
#endif

#pragma mark - View Setup

- (void)loadSettings
{
    CDVConfigParser *parser = [CDVConfigParser parseConfigFile:self.configFilePath];

    // Get the plugin dictionary, allowList and settings from the delegate.
    _pluginsMap = parser.pluginsDict;
    self.startupPluginNames = parser.startupPluginNames;
    self.settings = [[CDVSettingsDictionary alloc] initWithDictionary:parser.settings];

    // And the start page
    if(parser.startPage && self.startPage == nil){
        self.startPage = parser.startPage;
    }
    if (self.startPage == nil) {
        self.startPage = @"index.html";
    }

    self.appScheme = [self.settings cordovaSettingForKey:@"Scheme"] ?: @"app";
}

/// Retrieves the view from a newwly initialized webViewEngine
/// @param bounds The bounds with which the webViewEngine will be initialized
- (nonnull UIView*)newCordovaViewWithFrame:(CGRect)bounds
{
    NSString* defaultWebViewEngineClassName = [self.settings cordovaSettingForKey:@"CordovaDefaultWebViewEngine"];
    NSString* webViewEngineClassName = [self.settings cordovaSettingForKey:@"CordovaWebViewEngine"];

    if (!defaultWebViewEngineClassName) {
        defaultWebViewEngineClassName = @"CDVWebViewEngine";
    }
    if (!webViewEngineClassName) {
        webViewEngineClassName = defaultWebViewEngineClassName;
    }

    // Determine if a provided custom web view engine is sufficient
    id <CDVWebViewEngineProtocol> engine;
    Class customWebViewEngineClass = NSClassFromString(webViewEngineClassName);
    if (customWebViewEngineClass) {
        id customWebViewEngine = [self initWebViewEngine:customWebViewEngineClass bounds:bounds];
        BOOL customConformsToProtocol = [customWebViewEngine conformsToProtocol:@protocol(CDVWebViewEngineProtocol)];
        BOOL customCanLoad = [customWebViewEngine canLoadRequest:[NSURLRequest requestWithURL:self.appUrl]];
        if (customConformsToProtocol && customCanLoad) {
            engine = customWebViewEngine;
        }
    }

    // Otherwise use the default web view engine
    if (!engine) {
        Class defaultWebViewEngineClass = NSClassFromString(defaultWebViewEngineClassName);
        id defaultWebViewEngine = [self initWebViewEngine:defaultWebViewEngineClass bounds:bounds];
        NSAssert([defaultWebViewEngine conformsToProtocol:@protocol(CDVWebViewEngineProtocol)],
                 @"we expected the default web view engine to conform to the CDVWebViewEngineProtocol");
        engine = defaultWebViewEngine;
    }

    if ([engine isKindOfClass:[CDVPlugin class]]) {
        [self registerPlugin:(CDVPlugin*)engine withClassName:webViewEngineClassName];
    }

    _webViewEngine = engine;
    return _webViewEngine.engineWebView;
}

/// Initialiizes the webViewEngine, with config, if supported and provided
/// @param engineClass A class that must conform to the `CDVWebViewEngineProtocol`
/// @param bounds with which the webview will be initialized
- (id _Nullable) initWebViewEngine:(nonnull Class)engineClass bounds:(CGRect)bounds {
    WKWebViewConfiguration *config = [self respondsToSelector:@selector(configuration)] ? [self configuration] : nil;
    if (config && [engineClass instancesRespondToSelector:@selector(initWithFrame:configuration:)]) {
        return [[engineClass alloc] initWithFrame:bounds configuration:config];
    } else {
        return [[engineClass alloc] initWithFrame:bounds];
    }
}

- (void)createLaunchView
{
    CGRect webViewBounds = self.view.bounds;
    webViewBounds.origin = self.view.bounds.origin;

    UIView* view = [[UIView alloc] initWithFrame:webViewBounds];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view setAlpha:0];

    NSString* launchStoryboardName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UILaunchStoryboardName"];
    if (launchStoryboardName != nil) {
        UIStoryboard* storyboard = [UIStoryboard storyboardWithName:launchStoryboardName bundle:[NSBundle mainBundle]];
        UIViewController* vc = [storyboard instantiateInitialViewController];
        [self addChildViewController:vc];

        UIView* imgView = vc.view;
        imgView.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:imgView];

        [NSLayoutConstraint activateConstraints:@[
                [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeWidth multiplier:1 constant:0],
                [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeHeight multiplier:1 constant:0],
                [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
                [NSLayoutConstraint constraintWithItem:imgView attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:view attribute:NSLayoutAttributeCenterX multiplier:1 constant:0]
            ]];
    }

    self.launchView = view;
    [self.view addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
            [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeWidth multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeHeight multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeCenterY multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:self.view attribute:NSLayoutAttributeCenterX multiplier:1 constant:0]
        ]];
}

- (void)createGapView
{
    CGRect webViewBounds = self.view.bounds;
    webViewBounds.origin = self.view.bounds.origin;

    UIView* view = [self newCordovaViewWithFrame:webViewBounds];
    view.hidden = YES;
    view.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);

    if (@available(iOS 14.0, *)) {
        if (self.isClone) {
            WKWebView* cloneWebView = (WKWebView*) view;
            WKUserScript* script = [[WKUserScript alloc] initWithSource:@"window['__$cognifit$__isWebViewClone'] = true;" injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:true];
            [cloneWebView.configuration.userContentController addUserScript:script];

            self.cloneMessageHandler = [[CloneMessageHandler alloc] initWithViewController:self.cloneParent];
            WebViewWeakScriptMessageHandler *weakScriptMessageHandler = [[WebViewWeakScriptMessageHandler alloc] initWithScriptMessageHandler:self.cloneMessageHandler];
            [cloneWebView.configuration.userContentController addScriptMessageHandlerWithReply:weakScriptMessageHandler contentWorld:WKContentWorld.pageWorld name:@"webViewParent"];
        }
    }

    [self.view addSubview:view];
    [self.view sendSubviewToBack:view];

    if ([self.webView respondsToSelector:@selector(scrollView)]) {
        UIScrollView *scrollView = [self.webView performSelector:@selector(scrollView)];
        scrollView.delegate = self;
    }
}

- (void)createStatusBarView
{
#if !defined(TARGET_OS_VISION) || !TARGET_OS_VISION
    // If cordova-plugin-statusbar is loaded, we'll let it handle the status
    // bar to avoid introducing conflict
    if (NSClassFromString(@"CDVStatusBar") != nil)
        return;

    self.statusBar = [[UIView alloc] init];
    self.statusBar.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.statusBar];

    [self.statusBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    [self.statusBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;
    [self.statusBar.topAnchor constraintEqualToAnchor:self.view.topAnchor].active = YES;
    [self.statusBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor].active = YES;

    self.statusBar.hidden = YES;
#endif
}

- (void)loadStartPage
{
    NSURL *appURL = [self appUrl];

    if (appURL) {
        NSURLRequest *appReq = [NSURLRequest requestWithURL:appURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20.0];
        [_webViewEngine loadRequest:appReq];
    } else {
        NSString *loadErr = [NSString stringWithFormat:@"ERROR: Start Page at '%@/%@' was not found.", self.webContentFolderName, self.startPage];
        NSLog(@"%@", loadErr);

        NSURL *errorUrl = [self errorURL];
        if (errorUrl) {
            errorUrl = [NSURL URLWithString:[NSString stringWithFormat:@"?error=%@", [loadErr stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]] relativeToURL:errorUrl];
            NSLog(@"%@", [errorUrl absoluteString]);
            [_webViewEngine loadRequest:[NSURLRequest requestWithURL:errorUrl]];
        } else {
            NSString *html = [NSString stringWithFormat:@"<html><body> %@ </body></html>", loadErr];
            [_webViewEngine loadHTMLString:html baseURL:nil];
        }
    }
}

#pragma mark CordovaCommands

- (void)registerPlugin:(CDVPlugin*)plugin withClassName:(NSString*)className
{
    plugin.viewController = self;
    plugin.commandDelegate = _commandDelegate;

    @synchronized(_pluginObjects) {
        [_pluginObjects setObject:plugin forKey:className];
    }
    [plugin pluginInitialize];
}

- (void)registerPlugin:(CDVPlugin*)plugin withPluginName:(NSString*)pluginName
{
    plugin.viewController = self;
    plugin.commandDelegate = _commandDelegate;

    NSString* className = NSStringFromClass([plugin class]);

    @synchronized(_pluginObjects) {
        [_pluginObjects setObject:plugin forKey:className];
    }
    [_pluginsMap setValue:className forKey:[pluginName lowercaseString]];
    [plugin pluginInitialize];
}

/**
 Returns an instance of a CordovaCommand object, based on its name.  If one exists already, it is returned.
 */
- (nullable CDVPlugin *)getCommandInstance:(NSString *)pluginName
{
    // first, we try to find the pluginName in the pluginsMap
    // (acts as a allowList as well) if it does not exist, we return nil
    // NOTE: plugin names are matched as lowercase to avoid problems - however, a
    // possible issue is there can be duplicates possible if you had:
    // "org.apache.cordova.Foo" and "org.apache.cordova.foo" - only the lower-cased entry will match
    NSString* className = [_pluginsMap objectForKey:[pluginName lowercaseString]];

    if (className == nil) {
        return nil;
    }

    id obj = nil;
    @synchronized(_pluginObjects) {
        obj = [_pluginObjects objectForKey:className];
    }

    if (!obj) {
        obj = [[NSClassFromString(className) alloc] initWithWebViewEngine:_webViewEngine];
        if (!obj) {
            NSString* fullClassName = [NSString stringWithFormat:@"%@.%@",
                                       NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"],
                                       className];
            obj = [[NSClassFromString(fullClassName)alloc] initWithWebViewEngine:_webViewEngine];
        }

        if (obj != nil) {
            [self registerPlugin:obj withClassName:className];
        } else {
            NSLog(@"CDVPlugin class %@ (pluginName: %@) does not exist.", className, pluginName);
        }
    }
    return obj;
}

#pragma mark -

- (bool)isUrlEmpty:(NSURL *)url
{
    if (!url || (url == (id) [NSNull null])) {
        return true;
    }
    NSString *urlAsString = [url absoluteString];
    return (urlAsString == (id) [NSNull null] || [urlAsString length]==0 || [urlAsString isEqualToString:@"about:blank"]);
}

- (bool)checkAndReinitViewUrl
{
    NSURL* appURL = [self appUrl];
    if ([self isUrlEmpty: [_webViewEngine URL]] && ![self isUrlEmpty: appURL]) {
        [self loadStartPage];
        return true;
    }
    return false;
}

#pragma mark - API Methods for Plugins

- (void)showLaunchScreen:(BOOL)visible
{
    [self showSplashScreen:visible];
}

- (void)showSplashScreen:(BOOL)visible
{
    CGFloat fadeSplashScreenDuration = [self.settings cordovaFloatSettingForKey:@"FadeSplashScreenDuration" defaultValue:250.f];

    // Setting minimum value for fade to 0.25 seconds
    fadeSplashScreenDuration = fadeSplashScreenDuration < 250 ? 250 : fadeSplashScreenDuration;

    // AnimateWithDuration takes seconds but cordova documentation specifies milliseconds
    CGFloat fadeDuration = fadeSplashScreenDuration/1000;

    [UIView animateWithDuration:fadeDuration animations:^{
        [self.launchView setAlpha:(visible ? 1 : 0)];

        if (!visible) {
            [self.webView becomeFirstResponder];
        }
    }];
    if (!visible && !self.loadingScreenForClone) [self hideLoadingScreen];
}

// ///////////////////////

- (void)showLoadingScreenWithHTML:(NSString *)html baseURL:(NSURL *)baseURL
{
    [self loadViewIfNeeded];
    [self hideLoadingScreen];
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.systemBackgroundColor;
    if (html != nil) {
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        WKWebView *webView = [[WKWebView alloc] initWithFrame:overlay.bounds configuration:configuration];
        webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        webView.opaque = NO;
        webView.backgroundColor = UIColor.clearColor;
        webView.scrollView.scrollEnabled = NO;
        [overlay addSubview:webView];
        [webView loadHTMLString:html baseURL:baseURL];
    } else {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        spinner.center = CGPointMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds));
        spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [overlay addSubview:spinner];
        [spinner startAnimating];
    }
    self.backgroundView = overlay;
    [self.view addSubview:overlay];
}

- (void)hideLoadingScreen
{
    for (UIView *view in self.backgroundView.subviews) {
        if ([view isKindOfClass:WKWebView.class]) [(WKWebView *)view stopLoading];
    }
    [self.backgroundView removeFromSuperview];
    self.backgroundView = nil;
    self.loadingScreenForClone = NO;
}

- (void)showNativeBackgroundView:(NSString *)backgroundStyle andStrokeColor:(NSString *)strokeColor
{
    // Preserve app-supplied legacy resources; neither old style is required anymore.
    NSString *resource = [@"cordova-js-src/plugin/ios" stringByAppendingPathComponent:[backgroundStyle stringByAppendingPathExtension:@"html"]];
    NSString *path = [self.commandDelegate pathForResource:resource];
    if (!path) path = [NSBundle.mainBundle pathForResource:backgroundStyle ofType:@"html" inDirectory:@"www/cordova-js-src/plugin/ios"];
    NSString *html = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (html && strokeColor) {
        NSString *oldStroke = [backgroundStyle isEqualToString:@"loadingScreenStyle1"] ? @"stroke: #007cd5;" : @"stroke: #3399ff;";
        html = [html stringByReplacingOccurrencesOfString:oldStroke withString:[NSString stringWithFormat:@"stroke: %@;", strokeColor]];
    }
    [self showLoadingScreenWithHTML:html baseURL:path ? [NSURL fileURLWithPath:[path stringByDeletingLastPathComponent] isDirectory:YES] : nil];
    if (!html && strokeColor) {
        // Legacy apps normally pass a #RRGGBB stroke color.
        NSString *hex = [strokeColor hasPrefix:@"#"] ? [strokeColor substringFromIndex:1] : strokeColor;
        unsigned int rgb = 0;
        NSScanner *scanner = [NSScanner scannerWithString:hex];
        if (hex.length == 6 && [scanner scanHexInt:&rgb] && scanner.isAtEnd) {
            UIActivityIndicatorView *spinner = (UIActivityIndicatorView *)self.backgroundView.subviews.firstObject;
            spinner.color = [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
        }
    }
}

- (void)reloadAppWithLoadingScreenHTML:(NSString *)html baseURL:(NSURL *)baseURL
{
    [self dismissWebViewClone];
    [self showLoadingScreenWithHTML:html baseURL:baseURL];
    [self recreateAppWebView];
}

- (void)reloadAppWithBackgroundStyle:(NSString *)backgroundStyle andStrokeColor:(NSString *)strokeColor
{
    [self loadViewIfNeeded];
    [self dismissWebViewClone];
    if (backgroundStyle.length > 0 && ![backgroundStyle isEqualToString:@"nil"]) {
        [self showNativeBackgroundView:backgroundStyle andStrokeColor:strokeColor];
    } else {
        [self hideLoadingScreen];
    }

    [self recreateAppWebView];
}

- (void)recreateAppWebView
{
    WKWebView *webView = (WKWebView *)self.webView;
    [webView stopLoading];
    [webView.configuration.userContentController removeAllUserScripts];
    if (@available(iOS 14.0, *)) {
        [webView.configuration.userContentController removeAllScriptMessageHandlers];
    }
    [webView removeFromSuperview];
    @synchronized(_pluginObjects) {
        [[_pluginObjects allValues] makeObjectsPerformSelector:@selector(dispose)];
        [_pluginObjects removeAllObjects];
    }
    [_commandQueue dispose];
    _commandQueue = [[CDVCommandQueue alloc] initWithViewController:self];
    _commandDelegate = [[CDVCommandDelegateImpl alloc] initWithViewController:self];
    _webViewEngine = nil;
    self.loadCounter = 0;
    self.cloneReady = NO;
    [self createGapView];
    for (NSString *pluginName in self.startupPluginNames) {
        [self getCommandInstance:pluginName];
    }
    [self.webView setBackgroundColor:self.backgroundColor];
    [self loadStartPage];
}

- (BOOL)createWebViewClone
{
    return [self createWebViewCloneWithWebContentFolderName:self.webContentFolderName startPage:self.startPage];
}

- (BOOL)createWebViewCloneWithWebContentFolderName:(NSString *)folderName startPage:(NSString *)startPage
{
    if (@available(iOS 14.0, *)) {
        if (self.clone != nil || self.isClone || folderName.length == 0) return NO;
        self.clone = [[CDVViewController alloc] init];
        self.clone.isClone = YES;
        self.clone.cloneParent = self;
        self.clone.configFile = self.configFile;
        self.clone.webContentFolderName = folderName;
        self.clone.startPage = startPage;
        [self addChildViewController:self.clone];
        return YES;
    }
    return NO;
}

- (void)showWebViewCloneWithLoadingScreenHTML:(NSString *)html baseURL:(NSURL *)baseURL completionHandler:(VoidCompletionHandler)completionHandler
{
    if (self.clone && !self.clone.cloneReady) {
        [self showLoadingScreenWithHTML:html baseURL:baseURL];
        self.loadingScreenForClone = YES;
    }
    [self showWebViewClone:completionHandler];
}

- (void)showWebViewClone:(VoidCompletionHandler)completionHandler
{
    if (!self.clone) {
        if (completionHandler) completionHandler(NO);
        return;
    }
    self.clonePresentationRequested = YES;
    self.showWebViewCloneCompletionHandler = completionHandler;
    if (!self.clone.view.superview) {
        self.clone.view.frame = self.view.bounds;
        self.clone.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:self.clone.view];
        [self.view sendSubviewToBack:self.clone.view];
        [self.clone didMoveToParentViewController:self];
    }
    if (self.clone.cloneReady) {
        if (self.loadingScreenForClone) [self hideLoadingScreen];
        self.clone.view.hidden = NO;
        [self.view bringSubviewToFront:self.clone.view];
        self.showWebViewCloneCompletionHandler = nil;
        if (completionHandler) completionHandler(YES);
    }
}

- (BOOL)hideWebViewClone
{
    if (!self.clone) return NO;
    if (self.loadingScreenForClone) [self hideLoadingScreen];
    self.clonePresentationRequested = NO;
    self.clone.viewIfLoaded.hidden = YES;
    self.showWebViewCloneCompletionHandler = nil;
    return YES;
}

- (BOOL)dismissWebViewClone
{
    if (!self.clone) return NO;
    if (self.loadingScreenForClone) [self hideLoadingScreen];
    CDVViewController *clone = self.clone;
    [clone willMoveToParentViewController:nil];
    WKWebView *webView = (WKWebView *)clone.webView;
    [webView stopLoading];
    [webView.configuration.userContentController removeAllUserScripts];
    if (@available(iOS 14.0, *)) {
        [webView.configuration.userContentController removeAllScriptMessageHandlers];
    }
    clone.cloneMessageHandler = nil;
    [clone.viewIfLoaded removeFromSuperview];
    [clone removeFromParentViewController];
    self.clone = nil;
    self.clonePresentationRequested = NO;
    self.showWebViewCloneCompletionHandler = nil;
    self.loadTaskInWebViewCloneCompletionHandler = nil;
    return YES;
}

- (void)loadTaskInWebViewCloneWithJsCommand:(NSString* _Nonnull)jsCommand withCompletionHandler:(TaskCompletionHandler)completionHandler {
    if (self.clone) {
        self.loadTaskInWebViewCloneCompletionHandler = completionHandler;
        [self.clone.webViewEngine evaluateJavaScript:jsCommand completionHandler:^(id result, NSError* error) {

            // if we fail we don't care, we simply log for debugging
            NSLog(@"loadTaskInWebViewCloneWithJsCommand result: %@, error? %@", result, error);
        }];
    }
}

- (void)showStatusBar:(BOOL)visible
{
#if !defined(TARGET_OS_VISION) || !TARGET_OS_VISION
    [self.statusBar setAlpha:(visible ? 1 : 0)];
    [self setNeedsStatusBarAppearanceUpdate];
#endif
}

- (void)parseSettingsWithParser:(id <NSXMLParserDelegate>)delegate
{
    [CDVConfigParser parseConfigFile:self.configFilePath withDelegate:delegate];
}

@end

#pragma mark - CloneMessageHandler

@implementation CloneMessageHandler

- (instancetype)initWithViewController:(CDVViewController*)viewController {
    self = [super init];
    if (self) {
        _viewController = viewController;
    }
    return self;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message replyHandler:(void (^)(id _Nullable, NSString * _Nullable))replyHandler {
    CDVViewController *parent = self.viewController;
    if (!parent || message.webView != parent.clone.webView) {
        replyHandler(nil, @"The clone has been dismissed.");
        return;
    }
    if (![message.name isEqualToString:@"webViewParent"] || ![message.body isKindOfClass:[NSDictionary class]]) {
        replyHandler(nil, @"Invalid clone message.");
        return;
    }
    NSDictionary *body = message.body;
    NSString *title = body[@"title"];
    if (![title isKindOfClass:[NSString class]]) {
        replyHandler(nil, @"Missing clone message title.");
    } else if ([title isEqualToString:@"UP_AND_RUNNING"]) {
        parent.clone.cloneReady = YES;
        VoidCompletionHandler completion = parent.showWebViewCloneCompletionHandler;
        parent.showWebViewCloneCompletionHandler = nil;
        if (parent.clonePresentationRequested) {
            if (parent.loadingScreenForClone) [parent hideLoadingScreen];
            parent.clone.view.hidden = NO;
            [parent.view bringSubviewToFront:parent.clone.view];
            if (completion) completion(YES);
        }
        replyHandler(@"OK", nil);
    } else if ([title isEqualToString:@"TRAINING_TASK_FINISHED"]) {
        TaskCompletionHandler completion = parent.loadTaskInWebViewCloneCompletionHandler;
        parent.loadTaskInWebViewCloneCompletionHandler = nil;
        if (completion) completion(body);
        replyHandler(@"OK", nil);
    } else if ([title isEqualToString:@"CALL_ASYNC"] && [body[@"script"] isKindOfClass:[NSString class]]) {
        WKWebView *webView = (WKWebView *)parent.webView;
        [webView callAsyncJavaScript:body[@"script"] arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
            replyHandler(result, error.localizedDescription);
        }];
    } else {
        replyHandler(nil, @"Unknown clone message or invalid script.");
    }
}

@end

#pragma mark - WebViewWeakScriptMessageHandler

@implementation WebViewWeakScriptMessageHandler

- (instancetype)initWithScriptMessageHandler:(id<WKScriptMessageHandlerWithReply>)scriptMessageHandler
{
    self = [super init];
    if (self) {
        _scriptMessageHandler = scriptMessageHandler;
    }
    return self;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message replyHandler:(void (^)(id _Nullable, NSString * _Nullable))replyHandler {
    id<WKScriptMessageHandlerWithReply> handler = self.scriptMessageHandler;
    if (handler) {
        [handler userContentController:userContentController didReceiveScriptMessage:message replyHandler:replyHandler];
    } else {
        replyHandler(nil, @"The clone message handler has been released.");
    }
}

@end
