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

#import "CDVGameViewController.h"
#import "CDVGameHostScript.h"
#import "Plugins/CDVWebViewEngine/CDVURLSchemeHandler.h"

@implementation CDVGameViewController {
    WKWebView *_webView;
    BOOL _disposed;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _requests = [NSMutableDictionary dictionary];
        _sessionID = NSUUID.UUID.UUIDString;
    }
    return self;
}

- (WKWebView *)webView { return _webView; }

- (void)loadView
{
    self.view = [[UIView alloc] init];
    if (_disposed) return;
    if (@available(iOS 14.0, *)) {
        NSURL *root;
        if ([self.webContentFolderName hasPrefix:@"file://"]) root = [NSURL URLWithString:self.webContentFolderName];
        else if (self.webContentFolderName.isAbsolutePath) root = [NSURL fileURLWithPath:self.webContentFolderName isDirectory:YES];
        else root = [NSBundle.mainBundle URLForResource:self.webContentFolderName withExtension:nil];
        if (!root) {
            if (self.eventHandler) self.eventHandler(@"loadFailed", @{@"message": @"Game content root not found"});
            return;
        }
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        CDVURLSchemeHandler *assets = [[CDVURLSchemeHandler alloc] initWithContentRoot:root startPage:self.startPage scheme:@"cdvgame"];
        [config setURLSchemeHandler:assets forURLScheme:@"cdvgame"];
        [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:CDVGameHostScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
        [config.userContentController addScriptMessageHandlerWithReply:self.messageHandler contentWorld:WKContentWorld.pageWorld name:@"host"];
        [config.userContentController addScriptMessageHandlerWithReply:self.messageHandler contentWorld:WKContentWorld.pageWorld name:@"webViewParent"];
        _webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
        _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _webView.navigationDelegate = self;
        [self.view addSubview:_webView];
        NSURL *url = [NSURL URLWithString:self.startPage relativeToURL:[NSURL URLWithString:@"cdvgame://localhost/"]];
        [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    self.cloneReady = NO;
    [self.requests removeAllObjects];
    // A navigation gets a fresh session: late native results cannot target its scripts.
    self.sessionID = NSUUID.UUID.UUIDString;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    if (error.code != NSURLErrorCancelled && self.eventHandler) self.eventHandler(@"loadFailed", @{@"message": error.localizedDescription});
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [self webView:webView didFailProvisionalNavigation:navigation withError:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    self.cloneReady = NO;
    [self.requests removeAllObjects];
    self.sessionID = NSUUID.UUID.UUIDString;
    if (self.eventHandler) self.eventHandler(@"terminated", @{});
}

- (void)dispose
{
    _disposed = YES;
    self.cloneReady = NO;
    [self.requests removeAllObjects];
    [_webView stopLoading];
    _webView.navigationDelegate = nil;
    [_webView.configuration.userContentController removeAllUserScripts];
    if (@available(iOS 14.0, *)) [_webView.configuration.userContentController removeAllScriptMessageHandlers];
    [_webView removeFromSuperview];
    _webView = nil;
    self.messageHandler = nil;
    self.eventHandler = nil;
}

- (void)dealloc { [self dispose]; }
@end
