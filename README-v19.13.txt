J6Handset v19.13 — cold/relaunch outgoing audio pre-arm

Based on v19.12 native audio-route UI.

Changes:
- Outgoing CallKit actions pre-arm RelayController with DIALING before the BLE/Telecom state round-trip.
- CallKit remains the owner of AVAudioSession activation; this only makes didActivate start the relay immediately.
- BLE DIAL now carries the current iPhone Wi-Fi IPv4 atomically: CMD|DIAL|number|peerIPv4.
- A remote call is not sent if the iPhone has no usable Wi-Fi IPv4, preventing a call that can only fall back to J6-local audio.
- Existing AUDIO_PEER reconnect/network-change synchronization remains in place.

Unchanged:
- iOS 26 call controls / native audio route picker from v19.12
- audio wire format, UDP ports, jitter/playback path, CallKit mute/DTMF
- Messages/SMS/contact UI and persistence
