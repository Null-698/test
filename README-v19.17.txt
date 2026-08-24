J6Handset iOS v19.17 — SMS short incoming bubble alignment fix

Based directly on v19.16 (no Communication Notifications entitlement).

Fixed:
- Incoming SMS bubbles now align their content stack to the leading edge.
- Outgoing SMS bubbles remain trailing-aligned.
- The row itself is explicitly edge-aligned rather than relying on spacer geometry.
- The conversation LazyVStack explicitly fills the available width.

Cause:
- SMSBubbleRow used VStack(alignment: .trailing) for both directions.
- A short incoming bubble such as "Hi" was narrower than its timestamp, so the bubble
  was right-aligned to the timestamp width and appeared shifted toward the center.
- Longer incoming messages masked the bug because their bubble was already wider than
  the timestamp.

Unchanged:
- SMS send/receive transport, persistence, ACKs and delivery receipts
- Notifications (normal app-icon notifications; no Communication Notifications entitlement)
- Contact resolution
- OTP Copy Code
- CallKit
- BLE
- Call audio
- Android/Magisk
