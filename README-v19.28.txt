J6Handset iOS v19.28 — native centered Recents empty state

Changes from v19.27:
- The Recents empty state is no longer placed inside the SwiftUI List.
- When the active Recents filter has no matching calls, no List is created at all.
- Uses the native iOS ContentUnavailableView centered in the available content area.
- Empty states therefore have no list row inset, no leading gap, and no row separators/dividers.
- When calls exist, the native plain List and normal inter-call separators remain unchanged.
- The v19.27 native compact filter menu and first-row separator fix are preserved.
- No custom empty-state UI, divider, glass effect, or animation was added.
- All call history, CallKit, audio routing, BAD_CALL_ID protection, app icon, and no-Communication-Notifications configuration remain unchanged.
