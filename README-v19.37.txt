Cellular iOS v19.37 — warning-free iOS 26 call handoff

Based on v19.36.

Fixed the three deprecation warnings reported by the iOS 26 build:

1. INCallRecord caller
- Replaced deprecated `INCallRecord.caller` with the current `INCallRecord.participants` array.
- The first participant phone handle is still sanitized and sent through the same outgoing CallKit/BLE path.

2. UIApplication launch URL
- Removed the deprecated `UIApplication.LaunchOptionsKey.url` lookup.
- Cold and warm `tel:` URL handoffs remain handled by SwiftUI's scene-aware `.onOpenURL` entry point in ContentView.

3. UIApplication OpenURLOptionsKey
- Removed the deprecated app-delegate `application(_:open:options:)` callback.
- URL handling now has one iOS 26 scene-lifecycle source of truth instead of duplicate app-delegate and SwiftUI paths.

Preserved
- Modern `INStartCallIntent` and legacy `INStartAudioCallIntent` continuation support.
- Cold/warm NSUserActivity buffering and duplicate-request protection.
- v19.36 adaptive Light/Dark Mode colors and readable controls.
- v19.35 performance, Messages, custom call-screen, Settings wording, and carrier sender-name fixes.
- CallKit lifetime protections, BLE protocol, UDP/audio path, icon assets, and all entitlement behavior.

Suggested checks
1. Build with the iOS 26 SDK and confirm the caller, LaunchOptionsKey.url, and OpenURLOptionsKey warnings are gone.
2. Tap a Cellular call in the iPhone Phone app with Cellular already open.
3. Repeat after force-closing Cellular and confirm the app opens and starts the call.
4. Test a `tel:` handoff and confirm SwiftUI's scene handler starts the call once.
