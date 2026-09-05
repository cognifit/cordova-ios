# CogniFit migration to Cordova iOS 8.1

Base: Apache commit `f1011cf7a7a033539140d5678db15e1641607ae2` (8.1.1).
Fork customizations ported from `6a0ad949278f8f4797211df82258f93cf8ba3ea9`.

## Native integration

Use Cordova's built-in `CDVWebViewEngine`. Call the controller APIs on the main
thread. Configure the main controller before its view is loaded:

```objc
controller.webContentFolderName = @"www-main";
controller.startPage = @"index.html";
```

`webContentFolderName` accepts a folder relative to the main bundle, an absolute
filesystem directory, or a `file://` directory URL. This fork extends the built-in
asset handler and resource lookup to support downloaded directories as well as
bundled content. Include all required assets, Cordova JavaScript, and plugin
JavaScript in each web app's root. Do not use an absolute `startPage` to select a
local root: set the root separately and use a relative entry page.

```objc
BOOL created = [controller createWebViewCloneWithWebContentFolderName:downloadedAppDirectory
                                                          startPage:@"index.html?mode=training"];
if (created) {
    [controller showWebViewClone:^(BOOL ready) {
        // The clone has announced that it is ready and is now visible.
    }];
}

// Return to the main app, retaining the clone's loaded state.
[controller hideWebViewClone];
// Show the same clone again without reloading it.
[controller showWebViewClone:nil];
// Or destroy it, including its controller and plugins.
[controller dismissWebViewClone];
```

`createWebViewClone` remains available and snapshots the parent's current root,
start page and config-file path. The explicit creation method snapshots the supplied
root/start page and the parent's config-file path. A nil start page uses that
config's content entry. Creation returns NO if a clone already exists, if the root
is empty, if called on a clone, or on iOS below 14 (the reply bridge needs iOS 14).
Dismiss the existing clone before creating one with another root. The two roots
are independent; changing the parent does not change an existing clone.

To change the main root after loading:

```objc
controller.webContentFolderName = newAppDirectory;
controller.startPage = @"index.html";
[controller reloadAppWithBackgroundStyle:@"nil" andStrokeColor:nil];
```

Reload recreates the engine, command queue/delegate and plugins, and dismisses any
clone. It retains the controller's other views and does not manually re-enter
`viewDidLoad`. Startup plugins are initialized again. This method also works on
the clone controller, if accessed through the parent's child controllers.

## Existing JavaScript bridge

The clone still receives `window.__$cognifit$__isWebViewClone = true` at document
start. After it is ready to display, its main document must send:

```js
await window.webkit.messageHandlers.webViewParent.postMessage({
    title: 'UP_AND_RUNNING'
});
```

This message is required on first load even if `showWebViewClone` has no completion
block. Later hide/show calls reuse the ready clone without another handshake.

`loadTaskInWebViewCloneWithJsCommand:withCompletionHandler:` and the
`TRAINING_TASK_FINISHED` message are preserved. The task completion receives the
message dictionary. `CALL_ASYNC` still executes an async JavaScript body in the
parent and resolves/rejects the message's promise:

```js
const result = await window.webkit.messageHandlers.webViewParent.postMessage({
    title: 'CALL_ASYNC',
    script: 'return await someParentFunction();'
});
```

Use this bridge only with your trusted web apps. An invalid message now rejects
rather than leaving a promise unresolved.

`window.ionicWebViewLoadCounter` and `window.ionicIsColdBoot` are preserved and set
on each controller's own page-finished notification. The counter tracks completed
loads since engine creation, including explicit navigations and content-process
recovery; it is not exclusively a memory-pressure signal. Cold boot is a
process-wide flag, as in the old fork. Root separation does not isolate cookies,
localStorage, IndexedDB, or plugin global state: views with the same origin share
the default website data store.

## Removing cordova-plugin-ionic-webview from the app

The plugin is not required by the new root/clone implementation. Its engine uses
its own root handling, so remove it for this migration rather than expecting it to
honor the built-in engine's independent roots. Audit the app's usages before
removing the dependency and regenerate the iOS platform afterward.

The plugin's default branch was inspected at `a0af9c3`; the app's lockfile may pin
a different revision. The app and its custom plugins are outside this repository.

| Existing usage | Migration |
| --- | --- |
| `CordovaWebViewEngine = CDVWKWebViewEngine` / `IonicWebView` feature | Remove plugin-injected configuration; use built-in `CDVWebViewEngine`. |
| Engine class method `overrideWwwFolderName:` | Set the owning controller's `webContentFolderName` before loading. |
| `Ionic.WebView.convertFileSrc(path)` | `window.WkWebView.convertFilePath(path)` after Cordova initialization. |
| `window.WEBVIEW_SERVER_URL` | `window.CDV_ASSETS_URL`. |
| `Ionic.WebView.setServerBasePath(...)` | Have the app's native plugin set its own controller's root and reload it. There is no automatic JS compatibility alias. |
| `getServerBasePath` / `persistServerBasePath` | Implement app-owned root lookup/persistence; Cordova does not restore Ionic snapshot preferences automatically. |
| `Ionic.StopScroll` / `IonicStopScroll` | Audit callers; no replacement is added by this migration. |
| `iosScheme` | Set Cordova's `Scheme` preference; keep the existing `Hostname`. |

For an app currently served from `ionic://localhost`, preserve that origin:

```xml
<preference name="Scheme" value="ionic" />
<preference name="Hostname" value="localhost" />
```

Use the actual existing values if customized. Cordova defaults to `app://localhost`;
changing origin changes the web storage namespace and can affect authentication,
CORS and navigation rules. Verify an upgrade over an existing app installation.
Safari inspection is already supported upstream through `InspectableWebview`.

## Loading overlays

The two original `loadingScreenStyle*.html` assets and stroke-color customization
are retained under `cordova-js-src/plugin/ios`. As with the previous fork, arrange
for the app build to copy these HTML assets to
`www/cordova-js-src/plugin/ios/` (or the corresponding location under its custom
root). They are not automatically installed by the JavaScript bundler and
`cordova-js-src` is excluded from npm packaging. Lookup first uses the current
controller's root, then falls back to bundled `www`. A missing HTML asset leaves
the overlay unchanged rather than attempting to load a nil string.

Pass the legacy string `@"nil"` (or an empty string) to reload without an overlay.
`showNativeBackgroundView:andStrokeColor:` and both style names are unchanged.

## App verification

Check both bundled and downloaded roots, relative and root-relative assets,
first clone readiness, repeated hide/show/dismiss/recreate, parent async calls,
task completion, reload with each overlay and without one, orientation/status-bar
behavior, native plugins in each controller, content-process recovery, and memory
release after dismiss. Test stored login/data on an upgrade from the current app.
The repository tests exercise the built-in engine, not the app's plugin inventory.

## Repository validation

Validated with Xcode 26.6 and an iPhone 17 Pro simulator (iOS 26.5):

- Cordova framework simulator build succeeded.
- All 11 selected native tests passed (view controller and URL scheme handler),
  including real WKWebView roots/assets, clone message replies, task completion,
  invalid-message rejection, switching, and reload.
- `npm run lint` passed.
- `npm run test:unit`: 325 specs, 0 failures, including generated-app builds.

To repeat the native tests after `npm ci`:

```sh
xcodebuild test -workspace tests/cordova-ios.xcworkspace \
  -scheme CordovaTestApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CordovaTests/CDVViewControllerTest \
  -only-testing:CordovaTests/CDVURLSchemeHandlerTest \
  CODE_SIGNING_ALLOWED=NO
```

The complete native test suite and a physical-device build were not run.
