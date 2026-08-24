Cellular iOS v19.39 — background SMS notification visibility

Based on v19.38.

Fixed
- Keeping a conversation open no longer suppresses notifications after the app
  is minimized or otherwise leaves the active scene state.
- Incoming SMS is marked read without a banner only when the app is active and
  that exact conversation is actually onscreen.
- SMS received while the same conversation remains mounted in the background is
  now kept unread and creates the normal sound/banner/badge notification.
- Returning directly to the still-open conversation marks those messages read
  and clears its delivered notifications normally.
- The delayed contact-name lookup repeats the same app-active + visible-thread
  check, closing the race where the app changes state before scheduling finishes.

Preserved
- v19.38 quick-end outgoing-call cancellation and Phone-handoff deduplication.
- Android v24.8 pending-dial cancellation compatibility.
- v19.37 warning-free iOS 26 Phone-app handoff.
- Light/Dark Mode behavior, Messages layout/scrolling/composer behavior, custom
  call controls, Recents performance, carrier sender names, BLE, UDP/audio,
  app icon assets, and entitlement behavior.

Suggested checks
1. Open a conversation, leave it onscreen, and minimize the app.
2. Send a new SMS to that same conversation and confirm a notification appears.
3. Open the app directly and confirm the conversation marks the message read.
4. Keep the app active in that conversation and send another SMS; it should
   appear in place without a redundant notification banner.
