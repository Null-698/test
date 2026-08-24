J6Handset iOS v19.23

Based on v19.22. Audio is unchanged from v19.22/v19.20.

Fixes outgoing calls ending during slow carrier setup:
- STATE|ERROR|BAD_CALL_ID is now always treated as a command-level error and never replaces call state.
- A pre-carrier aggregate IDLE is ignored while an outgoing dial has been accepted by CallKit but Android Telecom has not yet published CONNECTING/DIALING/ACTIVE.
- Once CONNECTING/DIALING/ACTIVE has been observed, IDLE is authoritative again.
- DISCONNECTED remains authoritative at all times.
- Existing post-ACTIVE Call Again protection remains.
