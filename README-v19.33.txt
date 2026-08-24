J6Handset iOS v19.33 — LAN voice QoS only

- Marks the existing BSD UDP call-audio socket as NET_SERVICE_TYPE_VO.
- Keeps AVAudioPlayerNode and per-packet scheduling unchanged.
- Keeps the fixed 80 ms playback FIFO unchanged.
- Adds no adaptive jitter buffer, clock correction, packet-loss concealment,
  interpolation, resampling, or new crossfades.
- Packet format remains native PCM16LE mono 48 kHz / 10 ms / 976 bytes.
- All v19.32 carrier-state protections and prior UI behavior are unchanged.
