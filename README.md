# v19.20 Native-like Audio Route Control

Audio now behaves like the Phone/CallKit control: direct Receiver/Speaker toggle when no external route exists, menu only when Bluetooth is available, fixed icon with speaker highlight, and event-driven synchronization with the actual AVAudioSession route.

# J6Handset iOS v19.18 — Persistent Missed-Call Notifications

Based on v19.17.

Changes:
- Unanswered incoming GSM calls now create a normal local iPhone notification titled `Missed Call`.
- Notification body uses the fresh Contacts name when available and includes the formatted number.
- Each missed call has its own notification identifier, so multiple missed calls can remain in Notification Center.
- Calls rejected from the iPhone do not create missed-call notifications.
- Calls for which Answer was requested do not create missed-call notifications.
- Missed call-waiting calls are covered as well.
- CallKit still reports unanswered calls normally and keeps them in system Recents.
- No Communication Notifications entitlement, avatar enrichment, or entitlement diagnostics are used.

Unchanged:
- v19.17 SMS bubble alignment fix.
- SMS transport, persistence, OTP actions, and standard SMS notifications.
- Call audio, BLE, DTMF, CallKit contact identity, and route handling.
- Android and Magisk.
