J6Handset iOS v19.22

Emergency rollback after v19.21 audio regression.

Audio:
- Restored AudioBridge.swift exactly to v19.20 behavior.
- Restored v19.20 diagnostics/UI fields for audio.
- No PLC, no +/-1-sample clock correction, no 60 ms schedule target from v19.21.
- Restores v19.20 fixed 80 ms startup runway and deeper scheduled player runway.

Call state fixes retained from v19.21:
- Ignore transient STATE|ERROR|BAD_CALL_ID while a real call remains live.
- Once a call has reached ACTIVE, transient control errors cannot turn it into outgoing failure / Call Again.

Android and Magisk unchanged.
