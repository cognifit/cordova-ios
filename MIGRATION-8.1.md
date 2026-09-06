# CogniFit migration to Cordova iOS 8.1

Base: Apache `f1011cf7a7a033539140d5678db15e1641607ae2` (8.1.1).
Original fork: `6a0ad949278f8f4797211df82258f93cf8ba3ea9`.
Branch: `codex/8.1-independent-webviews`.

## Architecture and status

The main controller is the only Cordova/plugin owner. Switching main apps replaces
its webview, command delegate/queue and plugin instances. An optional clone is a
vanilla game WKWebView with no Cordova engine, plugin objects, plugin JavaScript,
or Cordova startup. It talks to the main controller through `window.host`.
There is no full-Cordova clone option or plugin compatibility registry.

Implemented: independent roots, main-app replacement, session/persistent app
selection, JSON handoff, vanilla clones, loaded-plugin discovery, native plugin
calls and repeated callbacks, bidirectional JSON messages, lifecycle hooks,
app-owned loading HTML, and a native spinner default.

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

This destroys any game clone, displays the native loading spinner, replaces the
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

## Vanilla game clones

```objc
BOOL created = [controller createWebViewCloneWithWebContentFolderName:gameDirectory
                                                          startPage:@"index.html?level=1"];
if (created) {
    [controller showWebViewCloneWithLoadingScreenHTML:nil baseURL:nil
                                  completionHandler:^(BOOL ready) {
        // YES: game announced readiness; NO: startup failed/could not show.
    }];
}
```

`createWebViewClone` snapshots the parent's root and start page. The explicit
method uses its supplied root; a nil entry page uses config.xml's content entry
(or index.html). Only one clone can exist per main controller. Creation returns
NO for an empty root, an existing clone, or iOS below 14. A successful create does
not validate that the web app will load successfully.

Clones are private UIViewController instances, not CDVViewController instances.
Do not cast child controllers to Cordova or use their plugin/engine APIs.
They serve local content at `cdvgame://localhost` with a new nonpersistent website
data store; main-app cookies and web storage are not shared, and game storage is
not retained after destruction. Account for this origin in game CORS/CSP rules.
Do not include cordova.js or plugin wrappers in the game's HTML.

The main-frame `window.host` bridge is injected at document start. The game calls:

```js
await host.ready();
```

Readiness reveals the clone and removes its startup overlay. `hideWebViewClone`
returns to the main view while retaining the game. `showWebViewClone:` shows a
ready game immediately without reloading. `dismissWebViewClone` disconnects and
releases the game, its handlers and outstanding result routes.

### Plugin discovery and calls

```js
const plugins = await host.getLoadedPlugins();
// [{ className: "SomeNativePlugin", services: ["someplugin"] }, ...]
const result = await host.callPlugin("SomePlugin", "someAction", [arg1, arg2]);
```

Discovery reports only native instances currently held by the main controller,
including internal plugins. `services` contains configured service names (usually
normalized to lowercase); it can be empty for a class registered without a service.
Installed but uninitialized plugins are not listed. A normal call may lazily
initialize a registered plugin through Cordova's standard command dispatcher.

Calls use the main controller's actual plugin objects. There is no per-game plugin
instance, action allowlist, compatibility assertion, or JavaScript wrapper shim.
Developers must use the plugin's native service/action/argument contract. A public
plugin JavaScript method may transform arguments and thus differ from this API.
Only trusted app/game content should receive this bridge.

`callPlugin` resolves with the first successful callback value or rejects with a
plugin error. A fourth argument overrides the default 30,000 ms timeout; use zero
to disable it. For multiple results or multipart callback arguments, use:

```js
const unsubscribe = host.subscribePlugin(
  "SomePlugin", "watch", [],
  (...values) => { /* result callback arguments */ },
  error => { /* plugin or bridge error */ }
);
unsubscribe();
```

Repeated callbacks follow Cordova's keepCallback flag. ArrayBuffer and multipart
result envelopes are decoded. Unsubscribe/timeout stops result delivery, not the
plugin's underlying native operation: invoke the plugin's documented stop method
when required. The bridge has no plugin-specific cancellation knowledge.

Session IDs and request IDs prevent results from a destroyed/navigated game from
reaching its replacement. Closing a game drops its routes; its JavaScript runtime
may already be gone and cannot be promised a final rejection callback.

### Messages and lifecycle

```js
// In the game:
await host.postMessage({ type: "gameFinished", score: 120 });
host.onmessage = message => { /* message from main/native app */ };
```

Native main integration:

```objc
controller.cloneEventHandler = ^(NSDictionary *event) {
    // type: "message", "loadFailed", or "terminated"; payload in "detail".
};
[controller postMessageToWebViewClone:@{@"type": @"pause"} completionHandler:nil];
```

The main page also receives `cordovacloneevent` CustomEvents with the same object
in `event.detail`. Sending to the game from main-page JavaScript can be exposed by
your existing native plugin through `postMessageToWebViewClone:completionHandler:`.

The game does not automatically reload, dismiss itself or select a fallback after
content-process termination. Native event delivery lets the consuming app decide.
For the main webview, upstream automatic recovery remains enabled by default:

```objc
controller.automaticWebViewRecoveryEnabled = NO;
controller.webViewTerminationHandler = ^{
    // App-owned recovery; JavaScript in the terminated main view cannot run.
};
```

Checkpoints, game results, retry policy and restoration belong to the consuming
app. A native process restart requires the app's normal startup/restoration path.
Destroying a WKWebView does not promise immediate reclamation of all WebKit/GPU
memory or survival of another view. WebKit controls process allocation.

### Legacy bridge compatibility

`window.__$cognifit$__isWebViewClone` and `webViewParent` messages remain available:
UP_AND_RUNNING aliases host.ready(); TRAINING_TASK_FINISHED delivers the legacy
native task completion; CALL_ASYNC executes an async JavaScript body in the main
webview and returns its result. `loadTaskInWebViewCloneWithJsCommand:withCompletionHandler:`
also remains available. New games can use the simpler host API.

The main view retains `ionicWebViewLoadCounter` and `ionicIsColdBoot` on completed
page loads. The counter includes explicit navigation and process recovery; it is
not solely a memory-pressure signal. Vanilla games have no Cordova load counters.

## Loading overlays

No packaged loading HTML files are required. Nil HTML selects a native spinner
that follows system light/dark appearance and creates no loading WKWebView:

```objc
[controller showLoadingScreenWithHTML:nil baseURL:nil];
[controller hideLoadingScreen];
```

Pass app-owned HTML to render it in a separate, lazily created WKWebView with no
Cordova/game bridge and a nonpersistent store:

```objc
[controller showLoadingScreenWithHTML:@"<html><body>Preparing…</body></html>"
                             baseURL:nil];
[controller reloadAppWithLoadingScreenHTML:loadingHTML baseURL:nil];
```

The HTML never replaces the game or main app. Prefer self-contained HTML/CSS and
embedded images. baseURL resolves relative URLs but grants no arbitrary local-file
access. WebKit startup is asynchronous; the overlay initially shows a system
background. An empty string is blank custom content; nil selects the spinner.

Reload overlays follow AutoHideSplashScreen/SplashScreenDelay. Disable automatic
splash dismissal if the app needs to retain an overlay until explicit readiness.
Clone startup overlays stay until host.ready(), hide or dismissal; parent splash
notifications cannot prematurely remove them. All loading views are released on
hide. Plain showWebViewClone: creates no loading screen.

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
change storage namespaces, login state, CORS and navigation behavior. The game
origin is intentionally separate. Safari inspection for the main view remains
controlled by upstream InspectableWebview.

## Validation and app integration

Validated on 2026-09-06 with Xcode 26.6 and iOS 26.5 (iPhone 17 Pro simulator):

- All 14 selected native tests passed, with no compiler warnings in the final run.
- npm run lint passed.
- npm run test:unit passed: 325 specs, zero failures, including generated-app builds.

The full native suite and physical-device memory-pressure tests were not run.


Native regression tests exercise real WKWebViews, separate game assets, no Cordova
in games, single-instance plugin calls, streaming results, timeout cleanup,
bidirectional messages, termination hooks, main-app replacement, JSON context and
selection restoration using a fresh controller. They simulate termination by
calling the delegate hook; they do not force an OS memory-pressure kill.

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
repeated heavy-app switching and game destruction on physical devices, background
transitions, orientation, auth/storage on upgrade, and recovery after process loss.
