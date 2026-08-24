J6Handset iOS v19.32 — authoritative carrier-state fix

- Treat every STATE|ERROR|<reason> packet as a command/control result, never as a GSM lifecycle state.
- Command errors can no longer replace DIALING/CONNECTING/ACTIVE or tear down CallKit/audio.
- BAD_CALL_ID remains covered by the broader rule.
- Only RINGING, CONNECTING, DIALING, ACTIVE, IDLE, and DISCONNECTED drive call lifetime.
- DISCONNECTED remains immediately authoritative.
- Existing slow-carrier pre-IDLE protection remains unchanged.
- No Android or Magisk changes required.
