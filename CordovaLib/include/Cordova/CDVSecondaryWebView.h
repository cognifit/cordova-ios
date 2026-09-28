/* Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements. See the NOTICE file distributed with this
 * work for additional information regarding copyright ownership.
 * The ASF licenses this file to you under the Apache License, Version 2.0. */
#import <Cordova/CDVPlugin.h>

/// Main-web-view-only Cordova service for one optional secondary web view.
@interface CDVSecondaryWebView : CDVPlugin
- (void)getCapabilities:(CDVInvokedUrlCommand *)command;
- (void)create:(CDVInvokedUrlCommand *)command;
- (void)destroy:(CDVInvokedUrlCommand *)command;
- (void)setTouchRegions:(CDVInvokedUrlCommand *)command;
- (void)send:(CDVInvokedUrlCommand *)command;
- (void)getMetrics:(CDVInvokedUrlCommand *)command;
- (void)pushSample:(id)sample streamName:(NSString *)streamName;
@end
