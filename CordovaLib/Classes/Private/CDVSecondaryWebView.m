/* Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements. See the NOTICE file distributed with this
 * work for additional information regarding copyright ownership.
 * The ASF licenses this file to you under the Apache License, Version 2.0. */
#import <Cordova/CDVSecondaryWebView.h>
#import <Cordova/CDVSecondaryWebViewStreams.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <math.h>
#import <limits.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <errno.h>

static uint64_t CDVSecondaryNanoseconds(uint64_t ticks) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return ticks * info.numer / info.denom;
}
static NSString *const CDVSecondaryScheme = @"secondary-content";
static NSString *const CDVSecondaryContentPolicy = @"default-src 'self' data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src 'self'; frame-src 'self'; form-action 'self'; object-src 'none'";
static NSUInteger const CDVSecondaryMaxMessageBytes = 1024 * 1024;

static NSMapTable<CDVSecondaryWebView *, NSDictionary<NSString *, NSDictionary *> *> *CDVSecondaryStreamRegistry(void) {
    static NSMapTable<CDVSecondaryWebView *, NSDictionary<NSString *, NSDictionary *> *> *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMapTable weakToStrongObjectsMapTable]; });
    return registry;
}
@interface CDVSecondaryStreamRateGate : NSObject
- (BOOL)reserveAtTime:(NSTimeInterval)now rateHz:(double)rateHz;
- (void)finishValid:(BOOL)valid;
@end

@implementation CDVSecondaryStreamRateGate {
    NSCondition *_condition;
    BOOL _inFlight;
    NSTimeInterval _lastAccepted;
    NSTimeInterval _reservedAt;
}
- (instancetype)init { if ((self = [super init])) _condition = [NSCondition new]; return self; }
- (BOOL)reserveAtTime:(NSTimeInterval)now rateHz:(double)rateHz {
    [_condition lock];
    while (_inFlight) [_condition wait];
    if (_lastAccepted != 0 && now - _lastAccepted < 0.9 / rateHz) { [_condition unlock]; return NO; }
    _inFlight = YES; _reservedAt = now;
    [_condition unlock];
    return YES;
}
- (void)finishValid:(BOOL)valid {
    [_condition lock];
    if (valid) _lastAccepted = _reservedAt;
    _inFlight = NO;
    [_condition broadcast];
    [_condition unlock];
}
@end

static NSMutableDictionary<NSString *, CDVSecondaryStreamRateGate *> *CDVSecondaryStreamRateGates(void) {
    static NSMutableDictionary<NSString *, CDVSecondaryStreamRateGate *> *gates;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gates = [NSMutableDictionary dictionary]; });
    return gates;
}
static id CDVSecondaryStreamSnapshot(id sample) {
    id value = sample ?: NSNull.null;
    @try {
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
        return encoded ? [NSJSONSerialization JSONObjectWithData:encoded options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    } @catch (NSException *exception) { return nil; }
}

static NSDictionary *CDVSecondaryError(NSString *code, NSString *message) {
    return @{ @"code": code, @"message": message ?: @"" };
}
static BOOL CDVSecondaryIsNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
        && isfinite([value doubleValue]);
}
static BOOL CDVSecondaryIsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static BOOL CDVSecondaryIsInteger(id value, double minimum, double maximum) {
    return CDVSecondaryIsNumber(value) && [value doubleValue] >= minimum && [value doubleValue] <= maximum
        && [value doubleValue] == floor([value doubleValue]);
}
static NSString *CDVSecondaryJSON(id value) {
    @try {
        if (!value || (![value isKindOfClass:NSString.class] && ![NSJSONSerialization isValidJSONObject:value])) return nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
        return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    } @catch (NSException *exception) { return nil; }
}
static BOOL CDVSecondaryWithin(NSString *path, NSString *root) {
    return [path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}
static BOOL CDVSecondaryValidEnvelope(NSDictionary *body) {
    NSString *kind = body[@"kind"];
    return [@[@"req", @"res", @"evt"] containsObject:kind ?: @""]
        && [body[@"id"] isKindOfClass:NSString.class] && [body[@"id"] length] > 0
        && [body[@"name"] isKindOfClass:NSString.class] && [body[@"name"] length] > 0
        && (body[@"payload"] || ([kind isEqual:@"res"] && body[@"err"]));
}
static NSString *CDVSecondaryMime(NSString *extension) {
    NSDictionary *types = @{ @"html": @"text/html", @"htm": @"text/html", @"css": @"text/css", @"js": @"application/javascript", @"mjs": @"application/javascript", @"wasm": @"application/wasm", @"json": @"application/json", @"svg": @"image/svg+xml", @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"webp": @"image/webp", @"woff": @"font/woff", @"woff2": @"font/woff2", @"txt": @"text/plain" };
    NSString *mime = types[extension.lowercaseString] ?: @"application/octet-stream";
    return [mime hasPrefix:@"text/"] || [@[@"application/javascript", @"application/json", @"image/svg+xml"] containsObject:mime]
        ? [mime stringByAppendingString:@"; charset=utf-8"] : mime;
}
static UIColor *CDVSecondaryColor(NSString *value) {
    if ([value isEqual:@"transparent"]) return UIColor.clearColor;
    if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"#"] || (value.length != 7 && value.length != 9)) return nil;
    NSString *hex = [value substringFromIndex:1];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    if ([hex rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    unsigned long long n = 0; [[NSScanner scannerWithString:hex] scanHexLongLong:&n];
    CGFloat r, g, b, a;
    if (hex.length == 6) { r = ((n >> 16) & 255) / 255.0; g = ((n >> 8) & 255) / 255.0; b = (n & 255) / 255.0; a = 1; }
    else { r = ((n >> 24) & 255) / 255.0; g = ((n >> 16) & 255) / 255.0; b = ((n >> 8) & 255) / 255.0; a = (n & 255) / 255.0; }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

@interface CDVSecondaryTouchView : UIView
@property (nonatomic, weak) UIView *secondary;
@property (nonatomic, weak) UIView *main;
@property (nonatomic) NSInteger mode;
@property (nonatomic, copy) NSArray<NSValue *> *rects;
@end
@implementation CDVSecondaryTouchView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    BOOL hit = self.mode == 2;
    if (self.mode == 1) for (NSValue *rect in self.rects) if (CGRectContainsPoint(rect.CGRectValue, point)) { hit = YES; break; }
    UIView *target = hit ? self.secondary : self.main;
    return [target hitTest:[self convertPoint:point toView:target] withEvent:event];
}
@end

@interface CDVSecondaryCancelGesture : UIGestureRecognizer
@property (nonatomic, strong) NSMutableSet<UITouch *> *activeTouches;
- (void)cancelActiveTouches;
- (void)setTrackingEnabled:(BOOL)enabled;
@end
@implementation CDVSecondaryCancelGesture
- (instancetype)init {
    if ((self = [super initWithTarget:nil action:nil])) {
        _activeTouches = [NSMutableSet set];
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self.activeTouches unionSet:touches]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.activeTouches minusSet:touches];
    if (!self.activeTouches.count && self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }
- (void)reset { [super reset]; [self.activeTouches removeAllObjects]; }
// Keep tracking a held finger after WebKit recognizes a pan, so a region update
// can still cancel it. Normal completion must fail rather than stay Possible.
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (void)cancelActiveTouches {
    if (self.activeTouches.count && self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateRecognized;
    [self.activeTouches removeAllObjects];
}
- (void)setTrackingEnabled:(BOOL)enabled {
    // UIKit resets the recognizer when disabled, including a recognized gesture
    // whose touchesCancelled callback will no longer be delivered.
    self.enabled = NO;
    [self.activeTouches removeAllObjects];
    self.enabled = enabled;
}
@end

@interface CDVSecondaryReadLease : NSObject
@property (nonatomic) BOOL valid;
@property (nonatomic) BOOL expired;
@property (nonatomic) BOOL readComplete;
- (BOOL)isValid;
- (BOOL)hasExpired;
- (BOOL)markComplete;
- (BOOL)invalidate;
- (BOOL)expire;
@end
@implementation CDVSecondaryReadLease
- (instancetype)init { if ((self = [super init])) _valid = YES; return self; }
- (BOOL)isValid { @synchronized (self) { return self.valid; } }
- (BOOL)hasExpired { @synchronized (self) { return self.expired; } }
- (BOOL)markComplete { @synchronized (self) { if (!self.valid) return NO; self.readComplete = YES; return YES; } }
- (BOOL)invalidate { @synchronized (self) { if (!self.valid) return NO; self.valid = NO; return YES; } }
- (BOOL)expire { @synchronized (self) { if (!self.valid || self.readComplete) return NO; self.expired = YES; self.valid = NO; return YES; } }
@end

@interface CDVSecondaryContent : NSObject <WKURLSchemeHandler>
@property (nonatomic, copy) NSArray<NSDictionary *> *roots;
@property (nonatomic) BOOL followSymlinks;
@property (nonatomic) NSInteger readLimit;
@property (nonatomic) NSInteger availablePermits;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *waiting;
@property (nonatomic, strong) NSMutableSet<CDVSecondaryReadLease *> *heldPermits;
@property (nonatomic) int64_t timeoutMs;
@property (nonatomic) int64_t watchdogMs;
@property (nonatomic) NSInteger cacheMaxAgeSeconds;
@property (nonatomic, copy) void (^record)(NSString *, uint64_t);
@property (nonatomic) BOOL perRequest;
@property (nonatomic, copy) void (^trace)(NSDictionary *);
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSURL *entryURL;
@property (nonatomic, copy) void (^assetError)(NSDictionary *);
@property (nonatomic, copy) void (^entryFailure)(NSString *);
@property (nonatomic, strong) NSMutableSet<NSString *> *assetErrorKeys;
@property (nonatomic) NSTimeInterval assetErrorWindow;
@property (nonatomic) NSUInteger assetErrorCount;
@property (nonatomic, strong) NSMutableSet *active;
@property (nonatomic, strong) NSMapTable *leases;
@end
@implementation CDVSecondaryContent
- (instancetype)init { if ((self = [super init])) { _active = [NSMutableSet set]; _leases = [NSMapTable strongToStrongObjectsMapTable]; _assetErrorKeys = [NSMutableSet set]; _waiting = [NSMutableArray array]; _heldPermits = [NSMutableSet set]; } return self; }
- (void)reportAssetError:(NSDictionary *)detail {
    if (!self.assetError) return;
    NSString *key = CDVSecondaryJSON(@[detail[@"rootIndex"], detail[@"path"], detail[@"status"], detail[@"reason"]]);
    BOOL emit = NO;
    @synchronized (self.assetErrorKeys) {
        NSTimeInterval now = CACurrentMediaTime();
        if (now - self.assetErrorWindow >= 1.0) { self.assetErrorWindow = now; self.assetErrorCount = 0; [self.assetErrorKeys removeAllObjects]; }
        if (![self.assetErrorKeys containsObject:key] && self.assetErrorCount < 10) {
            [self.assetErrorKeys addObject:key]; self.assetErrorCount++; emit = YES;
        }
    }
    if (emit) self.assetError(detail);
}
- (void)startWaitingReads {
    NSAssert(NSThread.isMainThread, @"Permit state belongs to the main thread");
    while (self.readLimit > 0 && self.availablePermits > 0 && self.waiting.count) {
        NSDictionary *next = self.waiting.firstObject;
        [self.waiting removeObjectAtIndex:0];
        CDVSecondaryReadLease *lease = next[@"lease"];
        if (![lease isValid]) continue;
        [self startRead:next];
    }
}
- (void)releasePermit:(CDVSecondaryReadLease *)lease {
    NSAssert(NSThread.isMainThread, @"Permit release belongs to the main thread");
    if (![self.heldPermits containsObject:lease]) return;
    [self.heldPermits removeObject:lease];
    self.availablePermits++;
    [self startWaitingReads];
}
- (void)startRead:(NSDictionary *)request {
    NSAssert(NSThread.isMainThread, @"Read admission belongs to the main thread");
    CDVSecondaryReadLease *lease = request[@"lease"];
    id<WKURLSchemeTask> task = request[@"task"];
    NSURL *url = request[@"url"];
    if (![lease isValid] || ![self.active containsObject:task]) return;
    if (self.readLimit > 0) { self.availablePermits--; [self.heldPermits addObject:lease]; }
    if (self.record) self.record(@"assetReadQueueWaitNs", CDVSecondaryNanoseconds(mach_absolute_time() - [request[@"queuedAt"] unsignedLongLongValue]));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.watchdogMs * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if ([lease expire]) [self deliverFailure:task url:url code:504 message:@"Asset read watchdog expired"];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self serveURL:url task:task lease:lease]; });
}
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSAssert(NSThread.isMainThread, @"Scheme tasks must start on the main thread");
    CDVSecondaryReadLease *lease = [[CDVSecondaryReadLease alloc] init];
    NSURL *url = task.request.URL;
    [self.active addObject:task];
    [self.leases setObject:lease forKey:task];
    NSDictionary *request = @{ @"task": task, @"url": url, @"lease": lease, @"queuedAt": @(mach_absolute_time()) };
    if (self.readLimit == 0 || self.availablePermits > 0) { [self startRead:request]; return; }
    [self.waiting addObject:request];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, self.timeoutMs * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (![self.waiting containsObject:request]) return;
        [self.waiting removeObject:request];
        if (![lease isValid]) return;
        if (self.record) self.record(@"permitTimeouts", 1);
        [self deliverFailure:task url:url code:503 message:@"Asset read permit timed out"];
    });
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSAssert(NSThread.isMainThread, @"Scheme tasks must stop on the main thread");
    [self.active removeObject:task];
    CDVSecondaryReadLease *lease = [self.leases objectForKey:task];
    [self.leases removeObjectForKey:task];
    if (lease) {
        [lease invalidate];
        NSIndexSet *queued = [self.waiting indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger index, BOOL *stop) { return entry[@"lease"] == lease; }];
        [self.waiting removeObjectsAtIndexes:queued];
        [self releasePermit:lease];
    }
}
- (void)cancelAll {
    NSAssert(NSThread.isMainThread, @"Scheme tasks must be canceled on the main thread");
    NSUInteger canceled = self.active.count;
    NSArray *leases = self.leases.objectEnumerator.allObjects;
    [self.active removeAllObjects];
    [self.leases removeAllObjects];
    [self.waiting removeAllObjects];
    if (canceled) NSLog(@"[SecondaryWebView] Canceled %lu active scheme tasks", (unsigned long)canceled);
    for (CDVSecondaryReadLease *lease in leases) { [lease invalidate]; [self releasePermit:lease]; }
}
- (NSUInteger)activeTaskCount {
    NSAssert(NSThread.isMainThread, @"Scheme task state belongs to the main thread");
    return self.active.count;
}
- (BOOL)deliver:(id<WKURLSchemeTask>)task response:(NSURLResponse *)response body:(NSData *)body {
    NSAssert(NSThread.isMainThread, @"Scheme task callbacks must run on the main thread");
    if (![self.active containsObject:task]) return NO;
    CDVSecondaryReadLease *lease = [self.leases objectForKey:task];
    BOOL completed = NO;
    @try {
        [task didReceiveResponse:response];
        if (![self.active containsObject:task]) return NO;
        if (body.length) [task didReceiveData:body];
        if (![self.active containsObject:task]) return NO;
        [task didFinish];
        completed = YES;
    } @catch (NSException *exception) {
        // WebKit can stop a task while one of its callbacks is in progress.
        NSLog(@"[SecondaryWebView] Scheme task delivery stopped: %@", exception.reason);
    } @finally {
        [self.active removeObject:task];
        [self.leases removeObjectForKey:task];
        if (lease) { [lease invalidate]; [self releasePermit:lease]; }
    }
    return completed;
}
- (void)fail:(id<WKURLSchemeTask>)task url:(NSURL *)url code:(NSInteger)code message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ [self deliverFailure:task url:url code:code message:message]; });
}
- (void)deliverFailure:(id<WKURLSchemeTask>)task url:(NSURL *)url code:(NSInteger)code message:(NSString *)message {
    NSAssert(NSThread.isMainThread, @"Scheme task callbacks must run on the main thread");
    if (![self.active containsObject:task]) return;
    NSString *path = url.path ?: @"";
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSString *relativePath = parts.count >= 4 && [parts[1] isEqualToString:@"r"]
        ? [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@"/"] : path;
    NSInteger rootIndex = parts.count >= 4 && [parts[1] isEqualToString:@"r"] && [[NSString stringWithFormat:@"%ld", (long)[parts[2] integerValue]] isEqualToString:parts[2]] ? [parts[2] integerValue] : -1;
    NSData *body = [message dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:@{
        @"Content-Type": @"text/plain; charset=utf-8", @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
        @"Cache-Control": @"no-store", @"Content-Security-Policy": CDVSecondaryContentPolicy
    }];
    if (self.record) self.record(code == 403 ? @"deniedPaths" : @"assetReadErrors", 1);
    if (self.perRequest && self.trace) self.trace(@{ @"path": path, @"status": @(code), @"durationNs": @0 });
    NSLog(@"[SecondaryWebView] Asset request failed (%ld): %@ (path: %@)", (long)code, message, relativePath);
    [self reportAssetError:@{ @"sessionId": self.sessionId ?: @"", @"path": relativePath,
        @"rootIndex": @(rootIndex), @"status": @(code), @"reason": message ?: @"Asset request failed" }];
    if ([url isEqual:self.entryURL] && self.entryFailure) self.entryFailure(message);
    [self deliver:task response:response body:body];
}
- (void)serveURL:(NSURL *)url task:(id<WKURLSchemeTask>)task lease:(CDVSecondaryReadLease *)lease {
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    if (![url.scheme isEqualToString:CDVSecondaryScheme] || ![url.host isEqualToString:@"localhost"] || parts.count < 4 || ![parts[1] isEqualToString:@"r"]) { [self fail:task url:url code:403 message:@"URL outside secondary content origin"]; return; }
    NSInteger index = [parts[2] integerValue];
    if (index < 0 || index >= (NSInteger)self.roots.count || ![[NSString stringWithFormat:@"%ld", (long)index] isEqualToString:parts[2]]) { [self fail:task url:url code:403 message:@"Unknown root"]; return; }
    NSDictionary *root = self.roots[index];
    NSString *relative = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@"/"];
    NSString *lexical = [[root[@"path"] stringByAppendingPathComponent:relative] stringByStandardizingPath];
    NSString *resolved = [lexical stringByResolvingSymlinksInPath];
    if (!CDVSecondaryWithin(lexical, root[@"path"]) || !CDVSecondaryWithin(resolved, root[@"path"]) || (!self.followSymlinks && ![lexical isEqualToString:resolved])) { [self fail:task url:url code:403 message:@"Path outside allowedRoots or symlink denied"]; return; }
    if (![lease isValid]) return;
    int descriptor = open(resolved.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        int code = errno;
        NSInteger status = code == EACCES ? 403 : code == EMFILE || code == ENFILE ? 503 : code == ENOENT || code == EISDIR ? 404 : 500;
        [self fail:task url:url code:status message:status == 403 ? @"Asset access denied" : status == 503 ? @"Too many open files" : status == 404 ? @"Asset not found" : @"Asset open failed"];
        return;
    }
    struct stat info;
    if (fstat(descriptor, &info) == 0 && S_ISDIR(info.st_mode)) {
        close(descriptor);
        [self fail:task url:url code:404 message:@"Asset not found"];
        return;
    }
    uint64_t readStart = mach_absolute_time();
    BOOL queued = NO;
    NSMutableData *body = [NSMutableData data];
    int readError = 0;
    BOOL reachedEOF = NO;
    while ([lease isValid]) {
        uint8_t bytes[64 * 1024];
        ssize_t count = read(descriptor, bytes, sizeof(bytes));
        if (count == 0) { reachedEOF = YES; break; }
        if (count < 0) { if (errno == EINTR) continue; readError = errno; break; }
        [body appendBytes:bytes length:(NSUInteger)count];
    }
    close(descriptor); // The reader alone owns and closes the descriptor, including on EOF.
    uint64_t duration = CDVSecondaryNanoseconds(mach_absolute_time() - readStart);
    if (self.record) { self.record(@"assetReadDurationNs", duration); self.record(@"assetReads", 1); }
    if (readError && [lease isValid]) {
        NSInteger status = readError == EACCES ? 403 : readError == EMFILE || readError == ENFILE ? 503 : readError == ENOENT || readError == EISDIR ? 404 : 500;
        [self fail:task url:url code:status message:status == 403 ? @"Asset access denied" : status == 503 ? @"Too many open files" : status == 404 ? @"Asset not found" : @"Asset read failed"];
    } else if (reachedEOF && [lease markComplete]) {
        NSData *completeBody = [body copy];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{
            @"Content-Type": CDVSecondaryMime(resolved.pathExtension),
            @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)completeBody.length],
            @"Cache-Control": [NSString stringWithFormat:@"private, max-age=%ld", (long)self.cacheMaxAgeSeconds],
            @"Content-Security-Policy": CDVSecondaryContentPolicy
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([lease hasExpired]) return;
            if ([self deliver:task response:response body:completeBody] && self.perRequest && self.trace)
                self.trace(@{ @"path": url.path ?: @"", @"status": @200, @"durationNs": @(duration) });
        });
        queued = YES;
    }
    if (!queued && !readError) dispatch_async(dispatch_get_main_queue(), ^{ [self releasePermit:lease]; });
}
@end

@interface CDVSecondaryWebView () <WKNavigationDelegate, WKScriptMessageHandlerWithReply>
@property (nonatomic, strong) WKWebView *secondary;
@property (nonatomic, strong) CDVSecondaryTouchView *touchView;
@property (nonatomic, copy) NSArray<CDVSecondaryCancelGesture *> *touchCancellations;
@property (nonatomic, strong) CDVSecondaryContent *content;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *eventCallbackId;
@property (nonatomic, copy) NSURL *entryDocumentURL;
@property (nonatomic) BOOL entryFailureEmitted;
@property (nonatomic, strong) NSTimer *heartbeat;
@property (nonatomic) NSTimeInterval createdAt;
@property (nonatomic) NSTimeInterval lastHeartbeat;
@property (nonatomic) NSInteger heartbeatMs;
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL terminated;
@property (nonatomic) BOOL unresponsive;
@property (nonatomic) BOOL backgrounded;
@property (nonatomic) BOOL countersEnabled;
@property (nonatomic) BOOL perRequestEnabled;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *traces;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *subscriptions;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, copy) NSSet<NSString *> *subscribedStreamNames;
@property (nonatomic, copy) NSSet<NSString *> *batchStreamNames;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *queuedLatest;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *queuedBatch;
@property (nonatomic) BOOL sampleDrainPosted;
- (void)rejectStreamSample;
- (void)enqueueStreamSample:(id)sample streamName:(NSString *)streamName;
@end
@implementation CDVSecondaryWebView {
    uint64_t _counters[14];
    uint64_t _histograms[5][8];
    __strong NSString *_pendingIds[64];
    NSTimeInterval _pendingTimes[64];
    NSUInteger _pendingCursor;
}
- (void)pluginInitialize {
    self.countersEnabled = YES;
    self.traces = [NSMutableArray array];
    self.subscriptions = [NSMutableDictionary dictionary];
    self.queuedLatest = [NSMutableDictionary dictionary];
    self.queuedBatch = [NSMutableDictionary dictionary];
    self.subscribedStreamNames = [NSSet set]; self.batchStreamNames = [NSSet set];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground) name:UIApplicationWillEnterForegroundNotification object:nil];
}
- (void)sendResult:(CDVPluginResult *)result callback:(NSString *)callback { [self.commandDelegate sendPluginResult:result callbackId:callback]; }
- (void)success:(id)value callback:(NSString *)callback {
    [self sendResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:value ?: @{}] callback:callback];
}
- (void)error:(NSString *)code message:(NSString *)message callback:(NSString *)callback {
    [self sendResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:CDVSecondaryError(code, message)] callback:callback];
}
- (void)record:(NSString *)name amount:(uint64_t)amount {
    if (!self.countersEnabled) return;
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"createToReadyNs", @"createToFirstPaintNs", @"assetReadDurationNs", @"assetReadQueueWaitNs", @"assetReads", @"deniedPaths", @"assetReadErrors", @"permitTimeouts", @"rendererDeaths", @"channelMessages", @"channelBytes", @"hangs", @"ipcRoundTripDurationNs", @"ipcRoundTrips"]; });
    NSUInteger index = [names indexOfObject:name];
    if (index == NSNotFound) return;
    @synchronized (self) {
        if (index < 2) _counters[index] = amount;
        else _counters[index] += amount;
        if (index < 4 || index == 12) {
            static const uint64_t limits[] = {1000000, 2000000, 4000000, 8000000, 16000000, 33000000, 100000000};
            NSUInteger bucket = 0; while (bucket < 7 && amount >= limits[bucket]) bucket++;
            _histograms[index == 12 ? 4 : index][bucket]++;
        }
    }
}
- (void)event:(NSString *)type detail:(id)detail {
    if (!self.eventCallbackId || !self.sessionId) return;
    NSDictionary *event = @{ @"sessionId": self.sessionId, @"type": type, @"detail": detail ?: NSNull.null };
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:event];
    [result setKeepCallbackAsBool:![type isEqualToString:@"destroyed"]];
    [self sendResult:result callback:self.eventCallbackId];
}
- (void)getCapabilities:(CDVInvokedUrlCommand *)command {
    [self success:@{ @"processIsolation": @NO, @"storageIsolation": @"origin", @"nativeHangDetection": @NO, @"binaryMessages": @NO, @"assetReadLimiter": @YES, @"maxProtocolVersion": @1 } callback:command.callbackId];
}
- (NSURL *)entryURL:(NSString *)value kind:(NSString **)kind {
    NSURL *url = [NSURL URLWithString:value];
    if ([url.scheme isEqualToString:@"file"]) { *kind = @"file"; return url.URLByStandardizingPath; }
    if (url.scheme.length) return nil;
    if ([value hasPrefix:@"/"]) { *kind = @"file"; return [NSURL fileURLWithPath:value]; }
    *kind = @"bundle";
    return [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:value];
}
- (void)create:(CDVInvokedUrlCommand *)command {
    if (self.secondary) { [self error:@"ALREADY_EXISTS" message:@"Destroy the current secondary web view first" callback:command.callbackId]; return; }
    NSDictionary *config = [command argumentAtIndex:0 withDefault:@{} andClass:NSDictionary.class];
    if (config[@"processWideMaxParallelAssetReads"]) { [self error:@"UNSUPPORTED_MODE" message:@"Process-wide read limiting is Android-only" callback:command.callbackId]; return; }
    if (config[@"telemetry"] && ![config[@"telemetry"] isKindOfClass:NSDictionary.class]) { [self error:@"INVALID_CONFIG" message:@"telemetry must be an object" callback:command.callbackId]; return; }
    NSString *url = config[@"url"];
    if (![url isKindOfClass:NSString.class] || url.length == 0) { [self error:@"INVALID_CONFIG" message:@"url is required" callback:command.callbackId]; return; }
    if (![config[@"processIsolation"] ?: @"shared" isEqual:@"shared"]) { [self error:@"UNSUPPORTED_MODE" message:@"iOS cannot force a separate WebKit content process" callback:command.callbackId]; return; }
    if (config[@"hardwareAccelerated"] && !CDVSecondaryIsBoolean(config[@"hardwareAccelerated"])) { [self error:@"INVALID_CONFIG" message:@"hardwareAccelerated must be boolean" callback:command.callbackId]; return; }
    if (config[@"hardwareAccelerated"] && ![config[@"hardwareAccelerated"] boolValue]) { [self error:@"UNSUPPORTED_MODE" message:@"Hardware acceleration cannot be disabled" callback:command.callbackId]; return; }
    NSString *storage = config[@"storageIsolation"] ?: @"origin";
    if ([storage isEqual:@"none"]) { [self error:@"UNSUPPORTED_MODE" message:@"The secondary custom scheme always has a distinct origin" callback:command.callbackId]; return; }
    if (![storage isEqual:@"ephemeral"] && ![storage isEqual:@"origin"]) { [self error:@"INVALID_CONFIG" message:@"storageIsolation must be origin or ephemeral" callback:command.callbackId]; return; }
    NSString *zOrder = config[@"zOrder"] ?: @"below";
    if (![zOrder isEqual:@"below"] && ![zOrder isEqual:@"above"]) { [self error:@"INVALID_CONFIG" message:@"Invalid zOrder" callback:command.callbackId]; return; }
    NSArray *versions = config[@"protocolVersions"];
    if (versions && (![versions isKindOfClass:NSArray.class] || ![versions containsObject:@1])) { [self error:@"PROTOCOL_MISMATCH" message:@"No common protocol version" callback:command.callbackId]; return; }
    id configuredReadLimit = config[@"maxParallelAssetReads"];
    if (configuredReadLimit == NSNull.null) configuredReadLimit = nil;
    if (configuredReadLimit && ![configuredReadLimit isEqual:@"unbounded"] && (![configuredReadLimit isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)configuredReadLimit) == CFBooleanGetTypeID() || [configuredReadLimit doubleValue] < 1 || [configuredReadLimit doubleValue] > INT_MAX || [configuredReadLimit doubleValue] != floor([configuredReadLimit doubleValue]))) { [self error:@"INVALID_CONFIG" message:@"maxParallelAssetReads must be a positive integer or unbounded" callback:command.callbackId]; return; }
    NSInteger readLimit = [configuredReadLimit isKindOfClass:NSNumber.class] ? [configuredReadLimit integerValue] : 0;
    for (NSString *key in @[@"assetReadTimeoutMs", @"assetReadWatchdogMs", @"assetCacheMaxAgeSeconds", @"heartbeatMs"]) {
        if (config[key] && !CDVSecondaryIsInteger(config[key], 0, 31536000)) { [self error:@"INVALID_CONFIG" message:[NSString stringWithFormat:@"%@ must be an integer", key] callback:command.callbackId]; return; }
    }
    for (NSString *key in @[@"opaque", @"followSymlinks"]) {
        if (config[key] && !CDVSecondaryIsBoolean(config[key])) { [self error:@"INVALID_CONFIG" message:[NSString stringWithFormat:@"%@ must be boolean", key] callback:command.callbackId]; return; }
    }
    NSDictionary *telemetryConfig = [config[@"telemetry"] isKindOfClass:NSDictionary.class] ? config[@"telemetry"] : @{};
    for (NSString *key in @[@"assetErrors", @"perRequest", @"counters"]) {
        if (telemetryConfig[key] && !CDVSecondaryIsBoolean(telemetryConfig[key])) { [self error:@"INVALID_CONFIG" message:[NSString stringWithFormat:@"telemetry.%@ must be boolean", key] callback:command.callbackId]; return; }
    }
    self.countersEnabled = !telemetryConfig[@"counters"] || [telemetryConfig[@"counters"] boolValue];
    id frameConfig = config[@"frame"];
    if ([frameConfig isKindOfClass:NSDictionary.class]) for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
        if (frameConfig[key] && !CDVSecondaryIsNumber(frameConfig[key])) { [self error:@"INVALID_CONFIG" message:[NSString stringWithFormat:@"frame.%@ must be numeric", key] callback:command.callbackId]; return; }
    }
    NSInteger timeout = config[@"assetReadTimeoutMs"] ? [config[@"assetReadTimeoutMs"] integerValue] : 5000;
    NSInteger watchdog = config[@"assetReadWatchdogMs"] ? [config[@"assetReadWatchdogMs"] integerValue] : 60000;
    NSInteger cacheMaxAge = config[@"assetCacheMaxAgeSeconds"] ? [config[@"assetCacheMaxAgeSeconds"] integerValue] : 3600;
    NSInteger heartbeat = config[@"heartbeatMs"] ? [config[@"heartbeatMs"] integerValue] : 2000;
    if (heartbeat > 0) heartbeat = MAX(500, heartbeat);
    if (readLimit < 0 || timeout < 1 || timeout > 60000 || watchdog < 1000 || watchdog > 300000 || cacheMaxAge < 0 || cacheMaxAge > 31536000 || heartbeat < 0) { [self error:@"INVALID_CONFIG" message:@"Invalid read limit, timeout, watchdog, cache age or heartbeat" callback:command.callbackId]; return; }
    BOOL opaque = [config[@"opaque"] boolValue];
    UIColor *background = CDVSecondaryColor(config[@"backgroundColor"] ?: @"transparent");
    if (!background || (opaque && CGColorGetAlpha(background.CGColor) < 1)) { [self error:@"INVALID_CONFIG" message:@"Invalid backgroundColor for opacity" callback:command.callbackId]; return; }
    NSString *entryKind;
    NSURL *entry = [self entryURL:url kind:&entryKind];
    if (!entry) { [self error:@"INVALID_CONFIG" message:@"url must be a local document" callback:command.callbackId]; return; }
    NSString *entryLexical = entry.URLByStandardizingPath.path;
    NSString *entryPath = entryLexical.stringByResolvingSymlinksInPath;
    if (![config[@"followSymlinks"] boolValue] && ![entryLexical isEqual:entryPath]) { [self error:@"PATH_DENIED" message:@"Entry document is a symlink" callback:command.callbackId]; return; }
    if ([entryKind isEqual:@"bundle"] && !CDVSecondaryWithin(entryPath, NSBundle.mainBundle.resourcePath.stringByResolvingSymlinksInPath)) { [self error:@"PATH_DENIED" message:@"Entry document is outside the app bundle" callback:command.callbackId]; return; }
    NSArray *declared = config[@"allowedRoots"];
    NSMutableArray *roots = [NSMutableArray array];
    if (!declared) [roots addObject:@{ @"path": entryPath.stringByDeletingLastPathComponent, @"kind": entryKind }];
    else if ([declared isKindOfClass:NSArray.class]) for (NSDictionary *r in declared) {
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"path"] isKindOfClass:NSString.class] || ![@[@"bundle", @"file"] containsObject:r[@"kind"]]) { [self error:@"INVALID_CONFIG" message:@"Each root needs path and kind" callback:command.callbackId]; return; }
        NSString *path = r[@"path"];
        if ([r[@"kind"] isEqual:@"bundle"] && !path.isAbsolutePath) path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:path];
        if ([r[@"kind"] isEqual:@"file"] && !path.isAbsolutePath) { [self error:@"INVALID_CONFIG" message:@"File roots must be absolute" callback:command.callbackId]; return; }
        NSString *lexical = path.stringByStandardizingPath;
        NSString *resolved = lexical.stringByResolvingSymlinksInPath;
        if ([r[@"kind"] isEqual:@"bundle"] && !CDVSecondaryWithin(resolved, NSBundle.mainBundle.resourcePath.stringByResolvingSymlinksInPath)) { [self error:@"INVALID_CONFIG" message:@"Bundle root is outside the app bundle" callback:command.callbackId]; return; }
        if (![config[@"followSymlinks"] boolValue] && ![lexical isEqualToString:resolved]) { [self error:@"INVALID_CONFIG" message:@"Root is a symlink" callback:command.callbackId]; return; }
        [roots addObject:@{ @"path": resolved, @"kind": r[@"kind"] }];
    }
    if (roots.count == 0) { [self error:@"INVALID_CONFIG" message:@"allowedRoots cannot be empty" callback:command.callbackId]; return; }
    NSInteger entryRoot = NSNotFound;
    for (NSUInteger i = 0; i < roots.count; i++) if (CDVSecondaryWithin(entryPath, roots[i][@"path"])) { entryRoot = (NSInteger)i; break; }
    if (entryRoot == NSNotFound) { [self error:@"PATH_DENIED" message:@"Entry document is outside allowedRoots" callback:command.callbackId]; return; }
    NSString *relative = [entryPath substringFromIndex:[roots[entryRoot][@"path"] length]];
    NSString *encoded = [relative stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *address = [NSString stringWithFormat:@"%@://localhost/r/%ld%@", CDVSecondaryScheme, (long)entryRoot, encoded];
    NSURL *initialURL = [NSURL URLWithString:address];
    if (!initialURL) { [self error:@"INVALID_CONFIG" message:@"Invalid local document URL" callback:command.callbackId]; return; }
    self.sessionId = NSUUID.UUID.UUIDString;
    self.content = [[CDVSecondaryContent alloc] init];
    self.content.sessionId = self.sessionId;
    self.content.roots = roots;
    self.content.followSymlinks = [config[@"followSymlinks"] boolValue];
    self.content.timeoutMs = timeout;
    self.content.watchdogMs = watchdog;
    self.content.cacheMaxAgeSeconds = cacheMaxAge;
    self.content.readLimit = readLimit;
    self.content.availablePermits = readLimit;
    __weak typeof(self) weakSelf = self;
    self.content.record = ^(NSString *name, uint64_t amount) { [weakSelf record:name amount:amount]; };
    self.content.entryURL = initialURL;
    self.entryDocumentURL = initialURL;
    self.entryFailureEmitted = NO;
    if ([config[@"telemetry"][@"assetErrors"] boolValue]) self.content.assetError = ^(NSDictionary *detail) {
        dispatch_async(dispatch_get_main_queue(), ^{ CDVSecondaryWebView *owner = weakSelf;
            if (owner && [owner.sessionId isEqualToString:detail[@"sessionId"]]) [owner event:@"assetError" detail:detail]; });
    };
    NSString *contentSession = self.sessionId;
    self.content.entryFailure = ^(NSString *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{ CDVSecondaryWebView *owner = weakSelf;
            if (owner && [owner.sessionId isEqualToString:contentSession]) [owner reportEntryFailure:reason]; });
    };
    self.perRequestEnabled = [config[@"telemetry"] isKindOfClass:NSDictionary.class] && [config[@"telemetry"][@"perRequest"] boolValue];
    self.content.perRequest = self.perRequestEnabled;
    self.content.trace = ^(NSDictionary *event) { CDVSecondaryWebView *owner = weakSelf; if (!owner) return; @synchronized (owner.traces) { [owner.traces addObject:event]; } };
    WKWebViewConfiguration *webConfig = [[WKWebViewConfiguration alloc] init];
    webConfig.websiteDataStore = [storage isEqual:@"origin"] ? WKWebsiteDataStore.defaultDataStore : WKWebsiteDataStore.nonPersistentDataStore;
    [webConfig setURLSchemeHandler:self.content forURLScheme:CDVSecondaryScheme];
    NSString *script = [self bootstrap:self.sessionId heartbeat:heartbeat];
    [webConfig.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    [webConfig.userContentController addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:@"secondaryWebView"];
    CGRect frame = self.viewController.view.bounds;
    id configuredFrame = config[@"frame"];
    if ([configuredFrame isKindOfClass:NSDictionary.class]) {
        NSDictionary *f = configuredFrame;
        frame = CGRectMake([f[@"x"] doubleValue], [f[@"y"] doubleValue], [f[@"width"] doubleValue], [f[@"height"] doubleValue]);
        if (frame.size.width < 0 || frame.size.height < 0) { [self error:@"INVALID_CONFIG" message:@"Invalid frame" callback:command.callbackId]; self.sessionId = nil; return; }
    } else if (configuredFrame && ![configuredFrame isEqual:@"fill"]) { [self error:@"INVALID_CONFIG" message:@"Invalid frame" callback:command.callbackId]; self.sessionId = nil; return; }
    self.secondary = [[WKWebView alloc] initWithFrame:frame configuration:webConfig];
    if (@available(iOS 16.4, *)) {
        WKWebView *mainWebView = [self.webView isKindOfClass:WKWebView.class] ? (WKWebView *)self.webView : nil;
        self.secondary.inspectable = mainWebView.isInspectable;
    }
    self.secondary.navigationDelegate = self;
    self.secondary.opaque = opaque;
    self.secondary.backgroundColor = background;
    self.secondary.scrollView.backgroundColor = self.secondary.backgroundColor;
    if (!configuredFrame || [configuredFrame isEqual:@"fill"]) self.secondary.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIView *main = self.webView;
    if ([zOrder isEqual:@"below"]) [self.viewController.view insertSubview:self.secondary belowSubview:main];
    else [self.viewController.view insertSubview:self.secondary aboveSubview:main];
    self.touchView = [[CDVSecondaryTouchView alloc] initWithFrame:self.viewController.view.bounds];
    self.touchView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.touchView.backgroundColor = UIColor.clearColor;
    self.touchView.secondary = self.secondary;
    self.touchView.main = main;
    [self.viewController.view addSubview:self.touchView];
    // Scope cancellation to the web views; do not compete on their shared parent.
    CDVSecondaryCancelGesture *mainCancellation = [CDVSecondaryCancelGesture new];
    CDVSecondaryCancelGesture *secondaryCancellation = [CDVSecondaryCancelGesture new];
    [main addGestureRecognizer:mainCancellation];
    [self.secondary addGestureRecognizer:secondaryCancellation];
    self.touchCancellations = @[mainCancellation, secondaryCancellation];
    self.eventCallbackId = command.callbackId;
    @synchronized (self) { memset(_counters, 0, sizeof(_counters)); memset(_histograms, 0, sizeof(_histograms)); for (NSUInteger i = 0; i < 64; i++) _pendingIds[i] = nil; _pendingCursor = 0; }
    @synchronized (self.traces) { [self.traces removeAllObjects]; }
    self.createdAt = CACurrentMediaTime(); self.lastHeartbeat = self.createdAt;
    self.heartbeatMs = heartbeat; self.ready = NO; self.terminated = NO; self.backgrounded = NO;
    if (heartbeat > 0) [self startHeartbeat];
    [self.secondary loadRequest:[NSURLRequest requestWithURL:initialURL]];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{ @"sessionId": self.sessionId, @"storageIsolation": storage }];
    [result setKeepCallbackAsBool:YES];
    [self sendResult:result callback:command.callbackId];
}
- (NSString *)bootstrap:(NSString *)session heartbeat:(NSInteger)heartbeat {
    return [NSString stringWithFormat:@"(() => { const s=%@;let seq=0;const pending=new Map(), listeners=new Map();const b64=a=>{let out='';new Uint8Array(a).forEach(x=>out+=String.fromCharCode(x));return btoa(out);};const unb64=x=>Uint8Array.from(atob(x),c=>c.charCodeAt(0)).buffer;const revive=x=>{if(!x||typeof x!=='object')return x;if(x.__secondaryArrayBuffer)return unb64(x.__secondaryArrayBuffer);if(Array.isArray(x))return x.map(revive);Object.keys(x).forEach(k=>x[k]=revive(x[k]));return x;}; const valid=(v,seen)=>{if(v===null||typeof v==='string'||typeof v==='boolean')return true;if(typeof v==='number')return Number.isFinite(v);if(typeof v!=='object'||seen.has(v))return false;let p=Object.getPrototypeOf(v);if(!Array.isArray(v)&&p!==null&&Object.getPrototypeOf(p)!==null||Object.getOwnPropertySymbols(v).length)return false;seen.add(v);let keys=Object.keys(v);if(Array.isArray(v)&&keys.length!==v.length)return false;for(let k of keys)if(!valid(v[k],seen))return false;seen.delete(v);return true;};const failure=c=>({code:c,message:c==='INVALID_JSON'?'Channel message is not valid JSON':c==='MESSAGE_TOO_LARGE'?'Channel message exceeds 1 MiB':'Reserved channel message name'});const report=c=>{try{window.webkit.messageHandlers.secondaryWebView.postMessage({v:1,id:'0',kind:'evt',name:'__secondaryChannelError',payload:c,sessionId:s}).catch(()=>{});}catch(_){}};const post=e=>{e.sessionId=s;if(e.payload instanceof ArrayBuffer)e.payload={__secondaryArrayBuffer:b64(e.payload)};try{if(e.name==='__secondaryChannelError')throw failure('INVALID_MESSAGE');if(!valid(e,new Set()))throw failure('INVALID_JSON');if(new TextEncoder().encode(JSON.stringify(e)).length>1048576)throw failure('MESSAGE_TOO_LARGE');}catch(x){let err=x&&x.code?x:failure('INVALID_JSON');console.warn('[SecondaryWebView] '+err.code+': '+err.message);report(err.code);return Promise.reject(err);}return window.webkit.messageHandlers.secondaryWebView.postMessage(e).then(r=>{if(r&&r.code)throw r;return r;}).catch(x=>{if(x&&x.code)throw x;return false;});}; const api={request(name,payload){let value=payload===undefined?null:payload;return new Promise((resolve,reject)=>{let id=String(++seq);pending.set(id,{resolve,reject});post({v:1,id,kind:'req',name,payload:value}).catch(err=>{pending.delete(id);reject(err);});});},post(name,payload){post({v:1,id:String(++seq),kind:'evt',name,payload:payload===undefined?null:payload}).catch(()=>{});},subscribe(name,options){return api.request('subscribe',{streamName:name,...options});},onMessage:null,unsubscribe(id){post({v:1,id:String(++seq),kind:'evt',name:'unsubscribe',payload:id}).catch(()=>{});},_receive(e){if(e.sessionId!==s||e.v!==1)return;e.payload=revive(e.payload);if(e.kind==='res'){let p=pending.get(e.id);if(p){pending.delete(e.id);e.err?p.reject(e.err):p.resolve(e.payload);}}else{if(api.onMessage)api.onMessage(e);let f=listeners.get(e.name);if(f)f.forEach(fn=>fn(e.payload));if(e.name==='streams')Object.keys(e.payload).forEach(id=>{let item=e.payload[id],f=listeners.get(item.streamName);if(f)f.forEach(fn=>fn(item.data,id));});}},on(name,fn){let f=listeners.get(name)||new Set();f.add(fn);listeners.set(name,f);return()=>f.delete(fn);}};Object.defineProperty(window,'secondaryWebView',{value:api});window.addEventListener('load',()=>{post({v:1,id:String(++seq),kind:'req',name:'handshake',payload:[1]}).then(ok=>{if(ok)requestAnimationFrame(()=>post({v:1,id:'0',kind:'evt',name:'firstPaint',payload:null}).catch(()=>{}));}).catch(()=>{});},{once:true});%@})();", CDVSecondaryJSON(session), heartbeat > 0 ? [NSString stringWithFormat:@"setInterval(()=>{post({v:1,id:'0',kind:'evt',name:'heartbeat',payload:null}).catch(()=>{});},%ld);", (long)MAX(500, heartbeat)] : @""];
}
- (void)setTouchRegions:(CDVInvokedUrlCommand *)command {
    if (!self.secondary) { [self error:@"NOT_CREATED" message:@"No secondary web view" callback:command.callbackId]; return; }
    if (self.terminated) { [self error:@"TERMINATED" message:@"Secondary content process has terminated" callback:command.callbackId]; return; }
    NSDictionary *value = [command argumentAtIndex:0 withDefault:@{} andClass:NSDictionary.class];
    NSString *mode = value[@"mode"] ?: @"none";
    NSInteger nextMode = [mode isEqual:@"none"] ? 0 : [mode isEqual:@"rects"] ? 1 : [mode isEqual:@"all"] ? 2 : -1;
    if (nextMode < 0) { [self error:@"INVALID_CONFIG" message:@"Invalid touch mode" callback:command.callbackId]; return; }
    NSMutableArray *rects = [NSMutableArray array];
    if (nextMode == 1 && ![value[@"rects"] isKindOfClass:NSArray.class]) { [self error:@"INVALID_CONFIG" message:@"rects must be an array" callback:command.callbackId]; return; }
    if (nextMode == 1) for (NSDictionary *r in value[@"rects"]) {
        BOOL valid = [r isKindOfClass:NSDictionary.class];
        if (valid) for (NSString *key in @[@"x", @"y", @"width", @"height"]) if (r[key] && !CDVSecondaryIsNumber(r[key])) valid = NO;
        if (!valid || !r[@"width"] || !r[@"height"] || [r[@"width"] doubleValue] < 0 || [r[@"height"] doubleValue] < 0) { [self error:@"INVALID_CONFIG" message:@"Invalid touch rectangle" callback:command.callbackId]; return; }
        [rects addObject:[NSValue valueWithCGRect:CGRectMake([r[@"x"] doubleValue], [r[@"y"] doubleValue], [r[@"width"] doubleValue], [r[@"height"] doubleValue])]];
    }
    for (CDVSecondaryCancelGesture *gesture in self.touchCancellations) [gesture cancelActiveTouches];
    self.touchView.rects = rects; self.touchView.mode = nextMode;
    [self success:@{} callback:command.callbackId];
}
- (void)send:(CDVInvokedUrlCommand *)command {
    if (!self.secondary) { [self error:@"NOT_CREATED" message:@"No secondary web view" callback:command.callbackId]; return; }
    if (self.terminated) { [self error:@"TERMINATED" message:@"Secondary content process has terminated" callback:command.callbackId]; return; }
    NSDictionary *envelope = [command argumentAtIndex:0 withDefault:@{} andClass:NSDictionary.class];
    if (envelope[@"sessionId"] && ![envelope[@"sessionId"] isEqual:self.sessionId]) { [self success:@{} callback:command.callbackId]; return; }
    if (!CDVSecondaryValidEnvelope(envelope)) { [self error:@"INVALID_MESSAGE" message:@"Envelope requires id, kind, name and payload or err" callback:command.callbackId]; return; }
    if ([envelope[@"name"] isEqual:@"__secondaryChannelError"]) { [self error:@"INVALID_MESSAGE" message:@"Reserved channel message name" callback:command.callbackId]; return; }
    NSMutableDictionary *wire = [envelope mutableCopy]; wire[@"v"] = @1; wire[@"sessionId"] = self.sessionId;
    NSString *json = CDVSecondaryJSON(wire);
    if (!json) { [self error:@"INVALID_JSON" message:@"Channel message is not valid JSON" callback:command.callbackId]; return; }
    if ([json lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > CDVSecondaryMaxMessageBytes) { [self error:@"MESSAGE_TOO_LARGE" message:@"Channel message exceeds 1 MiB" callback:command.callbackId]; return; }
    if ([wire[@"kind"] isEqual:@"req"]) { NSUInteger slot = _pendingCursor++ % 64; _pendingIds[slot] = wire[@"id"]; _pendingTimes[slot] = CACurrentMediaTime(); }
    [self.secondary evaluateJavaScript:[NSString stringWithFormat:@"window.secondaryWebView&&window.secondaryWebView._receive(%@)", json] completionHandler:nil];
    [self record:@"channelMessages" amount:1]; [self record:@"channelBytes" amount:[json lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    [self success:@{} callback:command.callbackId];
}
- (void)deliverEnvelope:(NSDictionary *)envelope {
    if (!self.secondary) return;
    NSMutableDictionary *wire = [envelope mutableCopy]; wire[@"v"] = @1; wire[@"sessionId"] = self.sessionId;
    NSString *json = CDVSecondaryJSON(wire);
    if (!json) { [self event:@"channelError" detail:@"INVALID_JSON"]; return; }
    if ([json lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > CDVSecondaryMaxMessageBytes) { [self event:@"channelError" detail:@"MESSAGE_TOO_LARGE"]; return; }
    [self.secondary evaluateJavaScript:[NSString stringWithFormat:@"window.secondaryWebView&&window.secondaryWebView._receive(%@)", json] completionHandler:nil];
    [self record:@"channelMessages" amount:1]; [self record:@"channelBytes" amount:[json lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
}
/// Native producers enqueue samples here. The display link sends at most one message per frame.
- (void)pushSample:(id)sample streamName:(NSString *)streamName {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self pushSample:sample streamName:streamName]; }); return; }
    if (!self.sessionId || self.backgrounded || ![self.subscribedStreamNames containsObject:streamName]) return;
    id snapshot = CDVSecondaryStreamSnapshot(sample);
    if (!snapshot) { [self rejectStreamSample]; return; }
    [self enqueueStreamSample:snapshot streamName:streamName];
}
- (void)enqueueStreamSample:(id)sample streamName:(NSString *)streamName {
    if (!self.sessionId || self.backgrounded || ![self.subscribedStreamNames containsObject:streamName]) return;
    BOOL schedule = NO;
    @synchronized (self.queuedLatest) {
        if ([self.batchStreamNames containsObject:streamName]) {
            NSMutableArray *values = self.queuedBatch[streamName];
            if (!values) { values = [NSMutableArray array]; self.queuedBatch[streamName] = values; }
            [values addObject:sample ?: NSNull.null];
        } else self.queuedLatest[streamName] = sample ?: NSNull.null;
        if (!self.sampleDrainPosted) { self.sampleDrainPosted = YES; schedule = YES; }
    }
    if (schedule) dispatch_async(dispatch_get_main_queue(), ^{ [self drainSamples]; });
}
- (void)rejectStreamSample { [self event:@"channelError" detail:@"INVALID_JSON"]; }
- (void)refreshStreamNames {
    NSMutableSet *all = [NSMutableSet set], *batches = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *rates = [NSMutableDictionary dictionary];
    for (NSDictionary *sub in self.subscriptions.allValues) {
        NSString *name = sub[@"streamName"];
        BOOL batch = [sub[@"coalesce"] isEqual:@"batch"];
        [all addObject:name]; if (batch) [batches addObject:name];
        NSMutableDictionary *info = rates[name];
        if (!info) { info = [@{ @"rateHz": @0, @"batch": @NO } mutableCopy]; rates[name] = info; }
        info[@"rateHz"] = @(MAX([info[@"rateHz"] doubleValue], [sub[@"rateHz"] doubleValue]));
        if (batch) info[@"batch"] = @YES;
    }
    self.subscribedStreamNames = all; self.batchStreamNames = batches;
    @synchronized ([CDVSecondaryWebViewStreams class]) {
        NSDictionary *previous = [CDVSecondaryStreamRegistry() objectForKey:self];
        for (NSString *name in previous) [CDVSecondaryStreamRateGates() removeObjectForKey:name];
        for (NSString *name in rates) [CDVSecondaryStreamRateGates() removeObjectForKey:name];
        if (self.secondary && !self.backgrounded && rates.count) [CDVSecondaryStreamRegistry() setObject:[rates copy] forKey:self];
        else [CDVSecondaryStreamRegistry() removeObjectForKey:self];
    }
}
- (id)serializableSample:(id)value {
    return [value isKindOfClass:NSData.class] ? @{ @"__secondaryArrayBuffer": [value base64EncodedStringWithOptions:0] } : value;
}
- (void)drainSamples {
    NSDictionary *latest, *batches;
    @synchronized (self.queuedLatest) {
        latest = [self.queuedLatest copy]; batches = [self.queuedBatch copy];
        [self.queuedLatest removeAllObjects]; [self.queuedBatch removeAllObjects]; self.sampleDrainPosted = NO;
    }
    if (!self.secondary || self.backgrounded || !self.ready) return;
    for (NSMutableDictionary *sub in self.subscriptions.allValues) {
        NSArray *values = batches[sub[@"streamName"]];
        id value = latest[sub[@"streamName"]];
        if ([sub[@"coalesce"] isEqual:@"batch"]) {
            if (values) for (id sample in values) [sub[@"batch"] addObject:[self serializableSample:sample]];
            else if (value) [sub[@"batch"] addObject:[self serializableSample:value]];
        } else if (values.count) sub[@"latest"] = [self serializableSample:values.lastObject];
        else if (value) sub[@"latest"] = [self serializableSample:value];
    }
}
- (void)flushFrame {
    if (!self.secondary || self.backgrounded) return;
    NSTimeInterval now = CACurrentMediaTime();
    NSMutableDictionary *frame = [NSMutableDictionary dictionary];
    for (NSString *subscriptionId in self.subscriptions.allKeys) {
        NSMutableDictionary *sub = self.subscriptions[subscriptionId];
        BOOL batch = [sub[@"coalesce"] isEqual:@"batch"];
        if (batch ? [sub[@"batch"] count] == 0 : !sub[@"latest"]) continue;
        if (now - [sub[@"lastDelivery"] doubleValue] < 1.0 / [sub[@"rateHz"] doubleValue]) continue;
        id data = batch ? [sub[@"batch"] copy] : sub[@"latest"];
        frame[subscriptionId] = @{ @"streamName": sub[@"streamName"], @"data": data };
        [sub removeObjectForKey:@"latest"];
        sub[@"batch"] = [NSMutableArray array];
        sub[@"lastDelivery"] = @(now);
    }
    if (frame.count) [self deliverEnvelope:@{ @"kind": @"evt", @"id": @"0", @"name": @"streams", @"payload": frame }];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message replyHandler:(void (^)(id, NSString *))replyHandler {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    if (!body || ![body[@"sessionId"] isEqual:self.sessionId] || self.backgrounded || self.terminated) { replyHandler(@NO, nil); return; }
    NSString *json = CDVSecondaryJSON(body);
    if (!json) { [self event:@"channelError" detail:@"INVALID_JSON"]; replyHandler(@{ @"code": @"INVALID_JSON", @"message": @"Channel message is not valid JSON" }, nil); return; }
    if ([json lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > CDVSecondaryMaxMessageBytes) { [self event:@"channelError" detail:@"MESSAGE_TOO_LARGE"]; replyHandler(@{ @"code": @"MESSAGE_TOO_LARGE", @"message": @"Channel message exceeds 1 MiB" }, nil); return; }
    NSString *name = body[@"name"];
    if ([name isEqual:@"handshake"]) {
        if (self.ready) { replyHandler(@YES, nil); return; }
        if (!CDVSecondaryValidEnvelope(body) || ![body[@"kind"] isEqual:@"req"] || ![body[@"payload"] isKindOfClass:NSArray.class] || ![body[@"payload"] containsObject:@1]) { [self event:@"loadFailed" detail:@"PROTOCOL_MISMATCH"]; [self.secondary stopLoading]; self.secondary.hidden = YES; replyHandler(@NO, nil); return; }
        self.ready = YES; [self record:@"createToReadyNs" amount:(uint64_t)((CACurrentMediaTime() - self.createdAt) * NSEC_PER_SEC)];
        [self deliverEnvelope:@{ @"kind": @"res", @"id": body[@"id"] ?: @"", @"name": @"handshake", @"payload": @1 }];
        [self event:@"ready" detail:nil]; replyHandler(@YES, nil); return;
    }
    if (!self.ready || !CDVSecondaryIsInteger(body[@"v"], 1, 1) || !CDVSecondaryValidEnvelope(body)) { [self event:@"channelError" detail:@"INVALID_MESSAGE"]; replyHandler(@NO, nil); return; }
    if ([name isEqual:@"__secondaryChannelError"]) {
        if ([body[@"kind"] isEqual:@"evt"] && [body[@"id"] isEqual:@"0"] && [@[@"INVALID_JSON", @"MESSAGE_TOO_LARGE", @"INVALID_MESSAGE"] containsObject:body[@"payload"]]) {
            [self event:@"channelError" detail:body[@"payload"]]; replyHandler(@YES, nil); return;
        }
        [self event:@"channelError" detail:@"INVALID_MESSAGE"]; replyHandler(@NO, nil); return;
    }
    if ([name isEqual:@"firstPaint"]) { if (self.ready) { [self record:@"createToFirstPaintNs" amount:(uint64_t)((CACurrentMediaTime() - self.createdAt) * NSEC_PER_SEC)]; [self event:@"firstPaint" detail:nil]; } replyHandler(@YES, nil); return; }
    if ([name isEqual:@"subscribe"] && [body[@"kind"] isEqual:@"req"]) {
        NSDictionary *options = [body[@"payload"] isKindOfClass:NSDictionary.class] ? body[@"payload"] : @{};
        BOOL validRate = !options[@"rateHz"] || CDVSecondaryIsInteger(options[@"rateHz"], 1, 60);
        NSInteger rate = validRate && options[@"rateHz"] ? [options[@"rateHz"] integerValue] : 60;
        NSString *coalesce = options[@"coalesce"] ?: @"latest";
        NSString *streamName = options[@"streamName"];
        NSMutableDictionary *answer = [@{ @"kind": @"res", @"id": body[@"id"] ?: @"", @"name": @"subscribe" } mutableCopy];
        if (![streamName isKindOfClass:NSString.class] || streamName.length == 0 || !validRate || rate < 1 || rate > 60 || ![@[@"latest", @"batch"] containsObject:coalesce]) answer[@"err"] = CDVSecondaryError(@"INVALID_SUBSCRIPTION", @"rateHz must be 1 to 60 and coalesce must be latest or batch");
        else {
            NSString *subscriptionId = NSUUID.UUID.UUIDString;
            self.subscriptions[subscriptionId] = [@{ @"streamName": streamName, @"rateHz": @(rate), @"coalesce": coalesce, @"batch": [NSMutableArray array], @"lastDelivery": @0 } mutableCopy];
            [self refreshStreamNames];
            answer[@"payload"] = subscriptionId;
            if (!self.displayLink) { self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(flushFrame)]; [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes]; }
        }
        [self deliverEnvelope:answer]; replyHandler(@YES, nil); return;
    }
    if ([name isEqual:@"unsubscribe"]) { if (![body[@"payload"] isKindOfClass:NSString.class]) { replyHandler(@NO, nil); return; } [self.subscriptions removeObjectForKey:body[@"payload"]]; [self refreshStreamNames]; if (self.subscriptions.count == 0) { [self.displayLink invalidate]; self.displayLink = nil; } replyHandler(@YES, nil); return; }
    if ([name isEqual:@"heartbeat"]) { self.lastHeartbeat = CACurrentMediaTime(); if (self.unresponsive) { self.unresponsive = NO; [self event:@"responsive" detail:nil]; } replyHandler(@YES, nil); return; }
    if ([body[@"kind"] isEqual:@"res"]) for (NSUInteger i = 0; i < 64; i++) if ([_pendingIds[i] isEqual:body[@"id"]]) {
        uint64_t elapsed = (uint64_t)((CACurrentMediaTime() - _pendingTimes[i]) * NSEC_PER_SEC);
        _pendingIds[i] = nil; [self record:@"ipcRoundTripDurationNs" amount:elapsed]; [self record:@"ipcRoundTrips" amount:1]; break;
    }
    [self record:@"channelMessages" amount:1]; [self record:@"channelBytes" amount:[json lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    [self event:@"message" detail:body]; replyHandler(@YES, nil);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    BOOL allowed = !self.terminated && [url.scheme isEqual:CDVSecondaryScheme] && [url.host isEqual:@"localhost"] && [url.path hasPrefix:@"/r/"];
    if (allowed) {
        NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
        NSInteger index = parts.count > 3 ? [parts[2] integerValue] : NSNotFound;
        allowed = index >= 0 && index < (NSInteger)self.content.roots.count && [[NSString stringWithFormat:@"%ld", (long)index] isEqual:parts[2]];
        if (allowed) {
            NSString *relative = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@"/"];
            NSString *root = self.content.roots[index][@"path"];
            NSString *lexical = [[root stringByAppendingPathComponent:relative] stringByStandardizingPath];
            NSString *resolved = lexical.stringByResolvingSymlinksInPath;
            allowed = CDVSecondaryWithin(lexical, root) && CDVSecondaryWithin(resolved, root) && (self.content.followSymlinks || [lexical isEqual:resolved]);
        }
    }
    if (!allowed) { [self record:@"deniedPaths" amount:1]; NSLog(@"[SecondaryWebView] Denied navigation: %@", url); }
    decisionHandler(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)reportEntryFailure:(NSString *)reason {
    if (!self.secondary || self.entryFailureEmitted) return;
    self.entryFailureEmitted = YES;
    [self event:@"loadFailed" detail:reason];
}
- (BOOL)isEntryNavigationError:(NSError *)error webView:(WKWebView *)webView {
    NSURL *failedURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    if (!failedURL) failedURL = [NSURL URLWithString:error.userInfo[NSURLErrorFailingURLStringErrorKey] ?: @""];
    if (!failedURL) failedURL = webView.URL;
    return failedURL && [failedURL isEqual:self.entryDocumentURL];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { if (error.code != NSURLErrorCancelled && [self isEntryNavigationError:error webView:webView]) [self reportEntryFailure:error.localizedDescription]; }
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { if (error.code != NSURLErrorCancelled && [self isEntryNavigationError:error webView:webView]) [self reportEntryFailure:error.localizedDescription]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [self record:@"rendererDeaths" amount:1]; self.ready = NO; self.terminated = YES; [self.content cancelAll]; [self.subscriptions removeAllObjects]; [self refreshStreamNames]; [self.displayLink invalidate]; self.displayLink = nil; [self event:@"terminated" detail:nil]; }
- (void)startHeartbeat {
    [self.heartbeat invalidate];
    self.heartbeat = [NSTimer scheduledTimerWithTimeInterval:self.heartbeatMs / 1000.0 repeats:YES block:^(NSTimer *timer) {
        if (!self.secondary || self.backgrounded || !self.ready) return;
        if (CACurrentMediaTime() - self.lastHeartbeat > self.heartbeatMs * 3 / 1000.0 && !self.unresponsive) { self.unresponsive = YES; [self record:@"hangs" amount:1]; [self event:@"unresponsive" detail:nil]; }
    }];
}
- (void)background { for (CDVSecondaryCancelGesture *gesture in self.touchCancellations) [gesture setTrackingEnabled:NO]; self.backgrounded = YES; [self.heartbeat invalidate]; self.heartbeat = nil; [self.subscriptions removeAllObjects]; [self refreshStreamNames]; @synchronized (self.queuedLatest) { [self.queuedLatest removeAllObjects]; [self.queuedBatch removeAllObjects]; } [self.displayLink invalidate]; self.displayLink = nil; }
- (void)foreground { for (CDVSecondaryCancelGesture *gesture in self.touchCancellations) [gesture setTrackingEnabled:YES]; self.backgrounded = NO; self.lastHeartbeat = CACurrentMediaTime(); if (self.secondary && self.heartbeatMs > 0) [self startHeartbeat]; }
- (void)onMemoryWarning { [self event:@"memoryPressure" detail:nil]; }
- (void)onAppTerminate { [self teardown]; }
- (void)getMetrics:(CDVInvokedUrlCommand *)command {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"createToReadyNs", @"createToFirstPaintNs", @"assetReadDurationNs", @"assetReadQueueWaitNs", @"assetReads", @"deniedPaths", @"assetReadErrors", @"permitTimeouts", @"rendererDeaths", @"channelMessages", @"channelBytes", @"hangs", @"ipcRoundTripDurationNs", @"ipcRoundTrips"]; });
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    @synchronized (self) {
        for (NSUInteger i = 0; i < names.count; i++) result[names[i]] = @(_counters[i]);
        NSArray *histNames = @[@"createToReadyHistogram", @"createToFirstPaintHistogram", @"assetReadDurationHistogram", @"assetReadQueueWaitHistogram", @"ipcRoundTripHistogram"];
        for (NSUInteger i = 0; i < histNames.count; i++) { NSMutableArray *bins = [NSMutableArray array]; for (NSUInteger j = 0; j < 8; j++) [bins addObject:@(_histograms[i][j])]; result[histNames[i]] = bins; }
        double seconds = MAX(0.001, CACurrentMediaTime() - self.createdAt);
        result[@"channelMessagesPerSecond"] = @(_counters[9] / seconds);
        result[@"channelBytesPerSecond"] = @(_counters[10] / seconds);
    }
    if (self.perRequestEnabled) { @synchronized (self.traces) { result[@"assetReadTraces"] = [self.traces copy]; } }
    result[@"activeSchemeTasks"] = @(self.content ? [self.content activeTaskCount] : 0);
    [self success:result callback:command.callbackId];
}
- (void)teardown {
    if (!self.secondary) return;
    [self event:@"destroyed" detail:nil];
    [self.heartbeat invalidate]; self.heartbeat = nil;
    [self.subscriptions removeAllObjects]; [self refreshStreamNames]; @synchronized (self.queuedLatest) { [self.queuedLatest removeAllObjects]; [self.queuedBatch removeAllObjects]; } [self.displayLink invalidate]; self.displayLink = nil;
    self.content.record = nil; self.content.trace = nil; self.content.assetError = nil; self.content.entryFailure = nil;
    [self.content cancelAll];
    [self.secondary stopLoading]; self.secondary.navigationDelegate = nil;
    [self.secondary.configuration.userContentController removeScriptMessageHandlerForName:@"secondaryWebView" contentWorld:WKContentWorld.pageWorld];
    [self.secondary.configuration.userContentController removeAllUserScripts];
    [self.secondary removeFromSuperview]; [self.touchView removeFromSuperview];
    for (CDVSecondaryCancelGesture *gesture in self.touchCancellations) [gesture.view removeGestureRecognizer:gesture];
    self.touchCancellations = nil;
    self.touchView.secondary = nil; self.touchView.main = nil; self.touchView = nil; self.secondary = nil; self.content = nil;
    @synchronized (self.traces) { [self.traces removeAllObjects]; }
    self.perRequestEnabled = NO;
    self.eventCallbackId = nil; self.sessionId = nil; self.entryDocumentURL = nil; self.ready = NO; self.terminated = NO;
}
- (void)destroy:(CDVInvokedUrlCommand *)command { [self teardown]; [self success:@{} callback:command.callbackId]; }
- (void)dispose { [self teardown]; [NSNotificationCenter.defaultCenter removeObserver:self]; [super dispose]; }
@end

@implementation CDVSecondaryWebViewStreams
+ (BOOL)hasSubscriberForStream:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    @synchronized (self) {
        NSMapTable *registry = CDVSecondaryStreamRegistry();
        for (CDVSecondaryWebView *owner in registry.keyEnumerator) if ([registry objectForKey:owner][name]) return YES;
    }
    return NO;
}
+ (double)maximumRateHzForStream:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || !name.length) return 0;
    double maximum = 0;
    @synchronized (self) {
        NSMapTable *registry = CDVSecondaryStreamRegistry();
        for (CDVSecondaryWebView *owner in registry.keyEnumerator) maximum = MAX(maximum, [[registry objectForKey:owner][name][@"rateHz"] doubleValue]);
    }
    return maximum;
}
+ (void)pushSample:(id)sample streamName:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || !name.length) return;
    NSMutableArray<CDVSecondaryWebView *> *owners = nil;
    double maximum = 0;
    BOOL batch = NO;
    CDVSecondaryStreamRateGate *gate = nil;
    @synchronized (self) {
        NSMapTable *registry = CDVSecondaryStreamRegistry();
        for (CDVSecondaryWebView *owner in registry.keyEnumerator) if ([registry objectForKey:owner][name]) {
            if (!owners) owners = [NSMutableArray array];
            [owners addObject:owner];
            NSDictionary *info = [registry objectForKey:owner][name];
            maximum = MAX(maximum, [info[@"rateHz"] doubleValue]);
            batch |= [info[@"batch"] boolValue];
        }
        if (owners.count && !batch) {
            gate = CDVSecondaryStreamRateGates()[name];
            if (!gate) { gate = [CDVSecondaryStreamRateGate new]; CDVSecondaryStreamRateGates()[name] = gate; }
        }
    }
    if (!owners.count) return;
    id snapshot;
    if (batch) snapshot = CDVSecondaryStreamSnapshot(sample);
    else {
        if (![gate reserveAtTime:CACurrentMediaTime() rateHz:maximum]) return;
        snapshot = CDVSecondaryStreamSnapshot(sample);
        [gate finishValid:(snapshot != nil)];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (CDVSecondaryWebView *owner in owners) {
            if (snapshot) [owner enqueueStreamSample:snapshot streamName:name];
            else if (owner.sessionId && !owner.backgrounded && [owner.subscribedStreamNames containsObject:name]) [owner rejectStreamSample];
        }
    });
}
@end
