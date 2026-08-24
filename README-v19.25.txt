J6Handset iOS v19.25 — CallHistoryStore Swift 6 actor-isolation cleanup

Based on v19.24 Recents / persistent call history.

Fixed:
- CallHistoryStore.storageURL() is now explicitly nonisolated.
- Removes the Swift 6 #ActorIsolatedCall warning when the background persistence queue resolves the call-history storage path.
- Persistence remains asynchronous on the existing utility queue; no file I/O was moved onto the MainActor.

Unchanged:
- Recents UI and call-history behavior from v19.24.
- v19.23 BAD_CALL_ID / slow-carrier call-state handling.
- v19.20+ audio route behavior.
- SMS behavior and notifications.
- App icon configuration.
- No Communication Notifications entitlement or entitlement diagnostics.
- No Android or Magisk changes.
