J6Handset v19.16 — remove Communication Notifications entitlement

Changes:
- Removed com.apple.developer.usernotifications.communication entitlement.
- Removed entitlementsPath from xtool.yml and deleted J6Handset.entitlements.
- Removed INSendMessageIntent communication-notification enrichment and avatar handoff.
- Incoming SMS notifications remain normal iOS local notifications using the resolved contact name as the title.
- Preserved OTP Copy Code action, notification deep-link to the correct conversation, badges, SMS persistence/ACK behavior, CallKit contact handling, audio, BLE, and all Android behavior.
- Kept INStartCallIntent activity declaration used by the call path.

No paid Communication Notifications capability is required.
