Cellular iOS v19.38 — quick-end outgoing-call cancellation

Based on v19.37.

Fixed
- Ending an outgoing call immediately after tapping Call now cancels its still-
  pending CallKit start transaction.
- A cancelled or stale CXStartCallAction can no longer send a delayed BLE DIAL.
- A CallKit start failure caused by that quick End can no longer enter the
  app-managed fallback path and dial the number again.
- A queued CallKit End for a not-yet-started outgoing call completes locally
  without sending an unnecessary second Hang Up command.
- Duplicate Phone-app handoffs are now matched by their stable intent interaction
  identity instead of relying only on a two-second timer. A delayed second copy
  of the same handoff can no longer start the call again after a quick End.

Preserved
- v19.37 warning-free iOS 26 Phone-app call handoff.
- v19.36 adaptive Light/Dark Mode behavior.
- v19.35 Recents/Messages performance and layout, custom call controls,
  generic Settings naming, and carrier sender-name resolution.
- CallKit lifetime protections, BLE protocol, UDP/audio path, app icon assets,
  and entitlement behavior.

Required companion
- Use Android v24.8 as well. It remembers Hang Up during Android's own
  prewarm/Telecom setup window, after iOS has already sent DIAL but before an
  Android Call object exists.

Suggested checks
1. Start a call and press End immediately, before the number begins ringing.
2. Repeat rapidly several times from the app keypad and Recents.
3. Repeat from an iPhone Phone-app handoff.
4. Confirm no carrier call appears afterward and no second End is required.
