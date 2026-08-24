Cellular iOS v19.36 — adaptive appearance and Phone-app call handoff

Based on v19.35.

1. Optimized Light Mode and Dark Mode
- Removed the forced Dark Mode override from the custom in-app call screen and the Call Ended screen.
- Both screens now follow the iPhone appearance setting automatically.
- Custom call backgrounds now begin with the native system background and use lower-intensity accent lighting in Light Mode.
- Call panels, route sheets, button fills, borders, primary text, secondary text, and selected states now use semantic iOS colors.
- The custom call UI remains fully custom; no native/custom button-style mixing was reintroduced.

2. Readable buttons, toggles, actions, and menus
- Replaced the app-wide `.primary` tint with the native system-blue action tint.
- Settings buttons, the diagnostics toggle, text-field cursor, Recents filter, Messages compose action, menus, and standard toolbar actions now keep the correct contrast in both appearances.
- Neutral keypad, delete, mute, DTMF, and route controls explicitly retain adaptive primary foreground colors instead of inheriting the blue action tint.
- Green call/send/answer actions and red end/delete actions retain white foregrounds for contrast.
- The custom audio-route panel now uses a native adaptive surface, semantic separators, and a system-blue selected route.

3. Calls started from the iPhone Phone app now dial
- Added the missing continuation handler for `INStartCallIntent`.
- Added compatibility for the legacy `INStartAudioCallIntent` activity that Phone/Recents can still deliver.
- Extracts the phone number from the intent contact or callback call record and forwards it through the existing `CallKitCoordinator.startOutgoing(number:)` path.
- Handles both warm launches and cold launches through one buffered request center.
- Handles `tel:` handoffs used by system calling surfaces as well as CallKit Recents activities.
- Duplicate delivery of the same system call request is suppressed for two seconds so one tap cannot start two transactions.
- The app switches to Keypad, restores the full call presentation, and starts the existing CallKit/BLE outgoing-call flow.

Unchanged
- v19.35 Recents/Contacts performance work, Messages bottom anchoring, fully custom in-app call controls, neutral Settings wording, and carrier sender-name handling.
- v19.34 compiled AppIcon asset catalog and notification icon metadata.
- v19.33 LAN voice QoS.
- Call lifetime protections, BAD_CALL_ID/command-error handling, audio-route serialization, BLE protocol, UDP audio, AVAudioPlayerNode, fixed 80 ms FIFO, packet handling, and fades.
- No Communication Notifications entitlement or other entitlement change.

Suggested checks
1. Switch the iPhone between Light and Dark appearance while viewing Keypad, Recents, Messages, Settings, an active call, the DTMF keypad, the audio-route panel, and Call Ended.
2. Confirm Settings toggles, toolbar/menu actions, glass buttons, disabled buttons, and destructive swipe actions remain readable in both appearances.
3. Place a call, end it, then tap its entry or Call action in the iPhone Phone app. Confirm Cellular opens and immediately starts the outgoing call rather than only opening the app.
4. Repeat the Phone-app test once with Cellular already open and once after force-closing it.
