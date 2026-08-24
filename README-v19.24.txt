J6Handset iOS v19.24 — in-app Recents / persistent call history

Based on v19.23 slow-carrier / BAD_CALL_ID call-state fix.

Added:
- New Recents tab beside Keypad.
- Incoming, outgoing, and missed call history.
- Contact name + phone number with fresh Contacts resolution.
- Contact photo/avatar in Recents when available.
- Date and time for every recent call.
- Missed calls are visually marked in red.
- All / Missed segmented filter.
- Tap a recent row to call back through the existing CallKit/J6 path.
- Swipe a recent row to delete it.
- Persistent call history stored locally in Application Support/call-history.json.
- Consecutive missed calls from the same number are grouped (within 24 hours).
- Call-waiting calls are recorded independently, including missed waiting calls.

Call-state integration:
- History is finalized only from the existing authoritative call teardown paths.
- Answered/connected state is tracked from actual ACTIVE call state.
- Rejected incoming calls are recorded as incoming, not as missed.
- Caller-hung-up-before-answer calls are recorded as missed.
- Failed outgoing attempts remain outgoing entries.
- BAD_CALL_ID handling from v19.23 is preserved unchanged in BLECallController.

Unchanged:
- v19.20+ audio routing/audio engine behavior.
- v19.23 slow-carrier outgoing setup protection.
- SMS behavior and notifications.
- No Communication Notifications entitlement or entitlement diagnostics.
- Android/J6 gateway remains headless; no Android or Magisk changes are required.
