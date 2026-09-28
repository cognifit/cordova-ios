# CogniFit migration to Cordova iOS 8.1

Base: Apache `f1011cf7a7a033539140d5678db15e1641607ae2` (8.1.1).
Original fork: `6a0ad949278f8f4797211df82258f93cf8ba3ea9`.
Branch: `codex/8.1-independent-webviews`.

## Architecture and status

The main controller is the only Cordova/plugin owner. Switching main apps replaces
its webview, command delegate/queue and plugin instances. Optional secondary
content uses `cordova.secondaryWebView` and a separate content origin.

Implemented: independent roots, main-app replacement, session/persistent app
selection, JSON handoff, secondary web views, app-owned loading HTML, and a
native spinner default.

All native controller APIs must be called on the main thread. Use the built-in
`CDVWebViewEngine` for the main app; remove the Ionic engine as described below.

## Main app roots and replacement

Before the main view loads, configure its root and entry page directly:

```objc
controller.webContentFolderName = @"www-main";
controller.startPage = @"index.html";
```

Roots can be main-bundle-relative directories, absolute directories, or `file://`
directory URLs. Use a relative entry page for local apps, including an optional
query and fragment. Each full main app needs its Cordova/plugin JavaScript and
assets. Paths should be supplied by the consuming app, not inferred from another
engine's global folder override.

For multiple main apps, register IDs before the main view loads:

```objc
NSError *error = nil;
BOOL configured = [controller configureWebApps:@{
    @"main": @{@"root": @"www-main", @"startPage": @"index.html"},
    @"assessment": @{@"root": @"www-assessment", @"startPage": @"index.html"}
} defaultAppID:@"main" error:&error];
// Handle configured == NO before proceeding.
```

Registration selects the remembered ID if still registered, otherwise the default.
It restores the selection before the initial view loads. Register all supported
IDs on each cold boot; removed IDs fall back to the default. The app is responsible
for ensuring registered directories and entry files exist.

```objc
BOOL accepted = [controller switchToWebApp:@"assessment"
                                remember:YES
                                 context:@{@"assessmentId": @123}
                                   error:&error];
// accepted means switching started; it does not mean the new app is ready.
```

This displays the native loading spinner, replaces the
main webview and plugins, and injects this object at document start:

```js
window.cordovaWebApp // { appId: "assessment", context: { assessmentId: 123 } }
```

The JSON context is copied at the switch boundary and stays in native memory for
this selection, including content-process reloads. It is not persisted across
native process restarts. Arbitrary JavaScript/native object references are not
supported. `activeWebAppID` and `webAppContext` expose the same state natively.

`remember:NO` changes only the running session; the previous remembered selection
is unchanged. `remember:YES` becomes persistent only when the new app signals
successful startup through your native integration:

```objc
[controller confirmWebAppReady];
```

Confirmation saves the pending ID and hides the loading overlay. The package does
not equate page-finished with business/application readiness. A failure before
confirmation leaves the previous cold-boot selection intact. `clearRememberedWebApp`
removes that selection without changing the running app. `webAppSelectionKey`
defaults to `CDVMainWebApp`; set it before registration if the app needs a separate
NSUserDefaults namespace. Only the ID is saved, not an absolute filesystem path.

These switching/confirmation APIs are native. Expose them through your app's
existing Cordova plugin if main-app JavaScript needs to initiate or confirm a
switch; there is no injected `host` in the main app.

The existing root-setter plus `reloadAppWithBackgroundStyle:andStrokeColor:` also
remains available for unmanaged switching. Do not mix direct root mutation with
registered app selection if you depend on `activeWebAppID`/handoff metadata.

### Plugin lifecycle

Plugins are disposed and reinitialized on a full main-app switch. Old command
delegates are invalidated so queued results cannot target the replacement page.
This does not stop arbitrary native work owned by third-party SDKs. There is no
universal solution for plugins that cannot safely initialize more than once;
review/fork incompatible plugins individually when encountered. Native state that
must survive a switch remains the consuming app's responsibility.

## Secondary web views

The legacy web-view-clone API, game-host bridge, and `CDVGameHostScript` have been removed on iOS. Android has also removed its `CordovaActivity`/`IndependentWebViewHost` clone API. Use `cordova.secondaryWebView` for independently rooted content; see [SECONDARY_WEB_VIEW.md](SECONDARY_WEB_VIEW.md) for both platforms' configuration and lifecycle.

The main web view still supports app-owned termination recovery through `automaticWebViewRecoveryEnabled` and `webViewTerminationHandler`.

## Loading overlays

No packaged loading HTML files are required. Nil HTML selects a native spinner
that follows system light/dark appearance and creates no loading WKWebView:

```objc
[controller showLoadingScreenWithHTML:nil baseURL:nil];
[controller hideLoadingScreen];
```

Pass app-owned HTML to render it in a separate, lazily created WKWebView with no
Cordova bridge and a nonpersistent store:

```objc
[controller showLoadingScreenWithHTML:@"<html><body>Preparing…</body></html>"
                             baseURL:nil];
[controller reloadAppWithLoadingScreenHTML:loadingHTML baseURL:nil];
```

The HTML never replaces the secondary or main app. Prefer self-contained HTML/CSS and
embedded images. baseURL resolves relative URLs but grants no arbitrary local-file
access. WebKit startup is asynchronous; the overlay initially shows a system
background. An empty string is blank custom content; nil selects the spinner.

Reload overlays follow AutoHideSplashScreen/SplashScreenDelay. Disable automatic
splash dismissal if the app needs to retain an overlay until explicit readiness.
All loading views are released on hide.

Legacy style methods still try optional app-owned HTML in
cordova-js-src/plugin/ios under the content root, then bundled www. Without a
matching file they use the native default. #RRGGBB stroke colors tint that spinner.
The legacy string @"nil" or an empty style reloads without an overlay.

## Removing cordova-plugin-ionic-webview

The plugin is not required. Its independent engine does not participate in this
root/host implementation. Remove it and its engine configuration, audit usages,
and regenerate the iOS platform. Its default branch was inspected at `a0af9c3`;
your app's lockfile may pin another revision.

| Existing usage | Replacement |
| --- | --- |
| CDVWKWebViewEngine / IonicWebView engine configuration | Built-in CDVWebViewEngine; remove plugin-injected configuration. |
| overrideWwwFolderName: | Set the owning main controller's webContentFolderName before loading. |
| Ionic.WebView.convertFileSrc(path) | window.WkWebView.convertFilePath(path) in the main Cordova page. |
| window.WEBVIEW_SERVER_URL | window.CDV_ASSETS_URL in the main page. |
| setServerBasePath | Native root switch/reload or registered switchToWebApp API. |
| getServerBasePath / persistServerBasePath | App-owned lookup or registered selection APIs; Ionic snapshot preferences are not imported. |
| Ionic.StopScroll / IonicStopScroll | Audit callers; no replacement included. |
| iosScheme | Cordova Scheme, preserving the existing Hostname. |

For an app previously served from ionic://localhost:

```xml
<preference name="Scheme" value="ionic" />
<preference name="Hostname" value="localhost" />
```

Preserve the actual existing values if customized. Changing the main origin can
change storage namespaces, login state, CORS and navigation behavior. The secondary content
origin is intentionally separate. Safari inspection for the main view remains
controlled by upstream InspectableWebview.

## Validation and app integration

The original migration validation predates removal of the clone implementation.
Build and test the current controller and secondary web view together; the old
clone-specific tests and bridge assertions no longer apply.

Run after npm ci:

```sh
xcodebuild test -workspace tests/cordova-ios.xcworkspace \
  -scheme CordovaTestApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CordovaTests/CDVViewControllerTest \
  -only-testing:CordovaTests/CDVURLSchemeHandlerTest \
  CODE_SIGNING_ALLOWED=NO
npm run lint
npm run test:unit
```

The consuming app still needs its native/JS integration for switching, readiness
confirmation and recovery, and must test its real plugin inventory. Exercise
repeated heavy-app switching and secondary-view destruction on physical devices, background
transitions, orientation, auth/storage on upgrade, and recovery after process loss.
