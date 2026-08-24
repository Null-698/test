J6Handset iOS v19.27 — native iOS 26 Recents filter toolbar fix

Based on v19.26 native Recents filtering.

Fixed Recents UI only:
- Replaced the direct toolbar Picker with a native SwiftUI Menu containing a Picker.
- The toolbar now presents as the compact iOS 26 filter button instead of a stretched selected-call-icon glass pill.
- The visible toolbar symbol is the standard three-horizontal-lines filter/menu symbol.
- The filter menu remains native and retains All Calls, Missed, Incoming, and Outgoing.
- Removed the separator above the first recent-call row using SwiftUI's native listRowSeparator API.
- Normal system separators between subsequent recent-call rows remain intact.
- Large native Recents navigation title remains unchanged.
- No custom glass, divider, popup, menu, or animation was added.

Preserved unchanged:
- Missed caller/contact names use system red.
- v19.25 CallHistoryStore actor-isolation fix.
- v19.23 BAD_CALL_ID / slow-carrier outgoing-call protection.
- v19.20+ audio-route/audio-engine behavior.
- Call-history persistence, grouping, call-back and native swipe-to-delete.
- SMS behavior and notifications.
- No Communication Notifications entitlement or entitlement diagnostics.
- Existing xtool app icon configuration.
- No Android or Magisk changes.
