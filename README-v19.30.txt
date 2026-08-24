J6Handset iOS v19.30 — iOS 26 notification app icon fix

Based on v19.29.

Changes:
- Keeps the existing 1024x1024 Resources/AppIcon.png and xtool iconPath unchanged.
- Adds modern CFBundleIcons -> CFBundlePrimaryIcon -> CFBundleIconFiles metadata.
- Adds top-level CFBundleIconFiles fallback metadata.
- Includes conventional 20pt, 29pt, 40pt, and 60pt @1x/@2x/@3x PNG variants of the same app icon so iOS 26 has an appropriately sized bundle icon for notifications and other system surfaces.
- No notification content/category/permission behavior changed.
- No changes to Calls, CallKit, Recents, Messages transport, audio routing, BLE, call-ID handling, or persistence.
- No Communication Notifications entitlement or entitlement diagnostics.

Note:
- xtool still injects CFBundleIconFile from iconPath as a legacy fallback at pack time.
