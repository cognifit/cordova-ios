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

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface CDVGameViewController : UIViewController <WKNavigationDelegate>
@property (nonatomic, copy) NSString *webContentFolderName;
@property (nonatomic, copy) NSString *startPage;
@property (nonatomic, readonly, nullable) WKWebView *webView;
@property (nonatomic, assign) BOOL cloneReady;
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, strong, nullable) id<WKScriptMessageHandlerWithReply> messageHandler;
@property (nonatomic, copy, nullable) void (^eventHandler)(NSString *, NSDictionary *);
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *requests;
- (void)dispose;
@end
NS_ASSUME_NONNULL_END
