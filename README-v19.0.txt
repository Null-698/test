iOS Stage 2 v19.0 - SMS Conversations

Built from v18.12 composer-centering baseline.

Adds:
- notification deep-link to exact SMS conversation
- contact-name notifications and contact-aware recipient suggestions
- per-thread unread state and active-thread notification suppression
- long-press Copy / Copy Code / Retry / Delete actions
- swipe-to-delete conversations
- failed-message Retry without creating a duplicate bubble
- robust Sent / Delivered state handling
- contact search in New Message; sending opens/reuses the canonical thread
- request-aware BLE disconnect failure handling

The stable v18.12 growing Liquid Glass composer layout is retained.
SMS/OTP bodies are not added to diagnostics.
