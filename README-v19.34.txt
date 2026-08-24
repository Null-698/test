J6Handset iOS v19.34 — notification app icon bundle fix

Based on v19.33.

Changes:
- Replaces the raw-PNG-only v19.30 workaround with a real compiled iOS asset catalog (`Resources/Assets.car`).
- Declares `AppIcon` as the primary icon through `CFBundleIconName` at the bundle and primary-icon levels.
- Includes the compiler-generated loose `AppIcon20x20`, `AppIcon29x29`, `AppIcon40x40`, and `AppIcon60x60` @2x/@3x PNG fallbacks in the app bundle root.
- Keeps xtool's `iconPath: Resources/AppIcon.png` as the legacy Home Screen fallback.
- Includes the source `Resources/Assets.xcassets/AppIcon.appiconset` used to compile the catalog.

Unchanged:
- SMS and missed-call notification content, scheduling, categories, permissions, and deep links.
- Calls, CallKit, Recents, Messages, audio routing, BLE, call-ID handling, persistence, and v19.33 LAN voice QoS.
- No Communication Notifications entitlement, notification avatar intent, or entitlement diagnostics.

Installation note:
- Install v19.34 over the current build, restart the iPhone once, then test with a newly generated SMS or missed-call notification.
- Only if the icon remains cached as blank, delete and reinstall the app as a last resort. Deleting the app also removes its local Messages/Recents/settings data.
