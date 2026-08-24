J6Handset v19.12 — native audio route control / no route-icon hitch

Changes only the in-call Audio route control and route-selection execution:
- Audio button now uses one fixed native SF Symbol (speaker.wave.2.fill).
- Removed route-specific iPhone/Speaker/AirPods icon swapping from the call UI.
- Route choices use a native SwiftUI Menu + Picker, so iOS renders selection/checkmarks.
- The label stays "Audio" instead of changing to iPhone/Speaker/Bluetooth.
- AVAudioSession route changes run on a dedicated Swift actor instead of MainActor,
  avoiding UI stalls while iOS switches receiver/speaker/Bluetooth HFP.
- Route changes are serialized and stale UI readbacks are ignored.
- Existing call audio, mute, DTMF, CallKit, BLE, SMS, and Messages UI are unchanged.
