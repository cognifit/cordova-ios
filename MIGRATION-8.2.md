# CogniFit migration to Cordova iOS 8.2

Branch: `codex/8.2-independent-webviews`.

This branch merges Apache's `rel/8.2.0` release (`f9bb658e`) into the latest
`codex/8.1-independent-webviews` fork (`c1b561f4`). Both histories are retained.
Apps can replace their existing Git dependency fragment with
`#codex/8.2-independent-webviews` and regenerate the iOS platform.

The fork APIs documented in [MIGRATION-8.1.md](MIGRATION-8.1.md) and
[SECONDARY_WEB_VIEW.md](SECONDARY_WEB_VIEW.md) remain available: independent
content roots, main-app replacement and persistent selection, JSON handoff,
loading overlays, termination recovery, inset configuration, secondary web views,
native streams, touch lifecycle handling, media playback, and asset byte ranges.

The controller merge keeps the cold-boot deviceready watchdog and app-selection
state while adopting upstream's status-bar background naming, visibility,
appearance, and layout changes. The upstream WKUIDelegate retention fix is
included, with an ownership correction from independent review: an engine holds
its owning controller weakly when that controller implements WKUIDelegate.
Default and external UI delegates remain retained. Disposing an engine during
app replacement clears both its retained delegate and the old web view's delegate.
The previously backported scene/deep-link fixes are also part of upstream 8.2.0.

Dependencies and the lockfile follow the release, including `xcode` 4 and
`devicectl` for physical-device deployment. The Git install's `prepare` script
regenerates Cordova JavaScript with the fork's secondary-web-view bridge.

Validation on 2026-11-13 (Node 22.23.4, Xcode 27.2, iPhone 17 simulator
running iOS 27.2):

- `npm ci`, lint, and the Cordova JavaScript bundle consistency check passed.
- `npm run cover`: 369 specs passed, including generated-app builds.
- `CordovaTestApp`: all 98 native tests passed in a single run.
- `SecondaryTouch`: all six UI cases passed across the suite and a targeted
  rerun. The background-during-touch test now waits for the asynchronous switch
  to Settings to reach the background state before checking resumed touches.

The native test harness now scopes deviceready notifications to their originating
web view. Previously, a late notification from another controller could release
a status-bar test before its own JavaScript was ready. No production API changes
were needed for this correction.

Independent-review follow-up reproduced a controller retain cycle in both initial
delegate setup and `updateWithInfo:` before the ownership correction. On an
iPhone 18 Pro simulator (iOS 27.2), the corrected engine passed all 101 native
tests, including three new lifetime regressions covering controller release,
external delegate retention, and app-switch disposal.

Consuming apps should still smoke-test their own plugin inventory, stored login
state, repeated app switching, secondary media, and background/foreground touch
behavior on physical devices before rollout.
