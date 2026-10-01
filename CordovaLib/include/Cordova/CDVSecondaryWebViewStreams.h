/* Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements. See the NOTICE file distributed with this
 * work for additional information regarding copyright ownership.
 * The ASF licenses this file to you under the Apache License, Version 2.0. */
#import <Foundation/Foundation.h>

/// Process-wide native producer for secondary web view streams.
@interface CDVSecondaryWebViewStreams : NSObject
+ (void)pushSample:(id)sample streamName:(NSString *)name;
+ (BOOL)hasSubscriberForStream:(NSString *)name;
@end
