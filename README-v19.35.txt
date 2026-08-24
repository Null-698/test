Cellular iOS v19.35 — scrolling, Messages, custom call UI, neutral Settings, carrier names

Based on v19.34.

1. Recents and Contacts performance
- Recents now derives and sorts its displayed groups once per render instead of rebuilding them again for each row separator.
- Contact metadata is cached by normalized participant and invalidated when Contacts access or the Contacts database changes.
- Concurrent lookups for the same participant share one Contacts request.
- Contact lookup status is no longer published for every row, preventing list-wide invalidation storms while scrolling.
- In-app contact fetches use Contacts thumbnails instead of loading full-resolution images.
- Contact avatars are downsampled and decoded away from the main thread, then held in a bounded memory cache.
- New-message contact searches cancel stale scans and stale results cannot replace the latest query.
- The 250 ms audio diagnostics timer now updates a dedicated diagnostics snapshot instead of publishing roughly twenty properties through the app-wide relay object.
- Settings observes that live diagnostics snapshot directly; unrelated Recents, Messages, and call controls no longer redraw for diagnostic counters.
- Audio-route state publishes only when the real available/selected route changes.
- Recents row identity and native List behavior remain unchanged.

2. Messages opens at the newest message and follows the keyboard
- A conversation now has an explicit bottom scroll anchor and jumps to it after its lazy content has laid out.
- New messages scroll to the newest bubble.
- The composer is installed with a bottom safe-area inset, so it stays above the keyboard and reserves the correct amount of space in the conversation.
- The conversation re-anchors when the composer gains focus, after the keyboard animation settles, and when the growing composer changes height.
- Message filtering/sorting is performed once per render instead of repeatedly for every bubble/day/status check.

3. Fully custom in-app call controls
- Removed all Liquid Glass ButtonStyle controls, GlassEffectContainer controls, native Menu, and native Picker usage from InAppCallView.
- Minimize, Mute, Audio, Keypad, DTMF, Answer, Decline, End Call, and route-selection rows now use one custom press/highlight system.
- Mute highlight still follows CallKit's real mute state.
- Audio highlight still follows AVAudioSession's real current route.
- Without Bluetooth, Audio directly toggles Receiver/Speaker.
- With Bluetooth, Audio opens a fully custom route panel instead of mixing a native menu gesture with a custom face.
- Route requests remain serialized by RelayController and DTMF still goes through CallKit.

4. Device-neutral Settings wording
- Replaced visible J6 wording with Relay, Uplink, or Downlink terminology throughout Settings.
- Dynamic Bluetooth/audio status text is sanitized only for Settings display.
- Internal property names, protocol identifiers, persistence paths, diagnostic filenames, and all log text are unchanged.

5. Carrier sender names
- Alphanumeric sender IDs such as carrier/service names are preserved as display names instead of being reduced to an empty normalized phone number.
- Sender names that also contain digits keep their complete identity and no longer collide with unrelated numeric short-code threads.
- The fix applies to the Messages list, conversation title, and SMS notification title.
- Normal phone-number Contacts matching and formatting are unchanged.

Unchanged
- v19.34 compiled AppIcon asset catalog and notification icon bundle metadata.
- v19.33 LAN voice QoS.
- Call lifetime, BAD_CALL_ID/command-error protection, BLE protocol, CallKit actions, audio route engine, AVAudioPlayerNode, fixed 80 ms FIFO, packet handling, and audio fades.
- SMS transport, persistence format, delivery status, OTP handling, and notification categories.
- No Communication Notifications entitlement.

Suggested checks
1. Rapidly scroll a long Recents list and a Messages/contact-suggestion list.
2. Open a long conversation and confirm the newest message is visible immediately.
3. Focus a multi-line composer and confirm the newest bubble remains above the composer and keyboard.
4. During a call, test Mute, Receiver/Speaker, Bluetooth route selection, and several DTMF digits.
5. Confirm Settings contains no visible J6 naming while exported/runtime logs retain their original text.
6. Receive an SMS from an alphanumeric carrier/service sender and confirm its name appears in Messages and the notification.
