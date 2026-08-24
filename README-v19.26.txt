J6Handset iOS v19.26 — native Recents layout + unified filtering

Based on v19.25 call-history actor-isolation fix.

Changed Recents UI only:
- Removed the custom Recents header and segmented All/Missed control.
- Recents is now one standard iOS NavigationStack/List surface.
- Uses the native navigation title and native toolbar Picker menu.
- Filter options: All Calls, Missed, Incoming, Outgoing.
- Missed caller/contact name is rendered in system red.
- Non-missed callers use the normal primary system label color.
- Restored standard List separators/background behavior.
- Removed the custom placeholder avatar circle/initials; the fallback is the native person.crop.circle SF Symbol.
- Contact photos continue to use the contact thumbnail when available.
- Swipe-to-delete remains the native SwiftUI swipe action.
- Empty states use ContentUnavailableView.
- No custom glass, custom filter animation, custom segmented control, or private Phone UI imitation is used.

Preserved unchanged:
- v19.25 nonisolated CallHistoryStore storageURL() actor-isolation fix.
- v19.23 BAD_CALL_ID / slow-carrier outgoing-call protection.
- v19.20+ audio-route and audio-engine behavior.
- Call history persistence/grouping/call-back behavior.
- SMS behavior and notifications.
- No Communication Notifications entitlement or entitlement diagnostics.
- Existing xtool app icon configuration.
- No Android or Magisk changes.
