# Appearance and navigation

The app automatically chooses full or reduced glass from recent raster timings
at the display's refresh rate. Slow windows reduce effects; eight healthy windows
are needed to restore them. System reduced transparency and high contrast still
win. Existing manual glass preferences no longer control the app.

Wallpapers include eight additional light/dark gradient presets. Custom photos
have independent dim and 0–24 blur controls. Legacy boolean blur preferences
migrate to intensity 6; motion is off by default. Photos remain device-local.

Optional Android depth uses the fused game rotation vector (gyroscope). Motion
is bounded and filtered, repaints only the background, respects Reduce motion,
and stops when hidden or backgrounded. Unsupported devices retain a static
wallpaper. No sensor permission or additional plugin is required.

Section swipes respect RTL and use screen-scaled distances plus deliberate fling
thresholds. Folder paging retains priority over shell navigation. Chat opening
and tab changes use bounded slide/fade transitions and respect reduced motion.
Outgoing chat pages cannot clear a newer page's presence watcher.

## Device-local deletion

Message actions and the chat menu offer clearly labeled device-local deletion
with confirmation. SQLite schema 5 records message client-ID tombstones and a
conversation history cutoff. Sync and DTN copies cannot restore a known deleted
message. A fresh message or explicitly starting the chat makes it visible again,
while the old history remains suppressed. Server order cutoffs exclude local
microsecond timestamps. Pending local sends are cancelled atomically; a request
already in flight may still complete.

This does not recall messages on other devices, remove server copies, or wipe
SQLite/WAL pages or downloaded media. Delete-for-everyone requires an authorized,
replay-safe server event and federation propagation and is not exposed here.

## Validation

Run storage deletion, messaging-store, offline ordering and group-store tests.
Run wallpaper preference migration tests and existing navigation/widget tests.
Verify sensor response, background pause/resume, RTL gestures and animations on
an Android device; static analysis cannot measure animation smoothness.
