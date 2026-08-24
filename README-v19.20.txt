J6Handset iOS v19.20 — Native-like Audio Route Control

Changes from v19.19:
- With only receiver + speaker available, Audio is now a one-tap toggle. No menu is shown.
- The Audio icon stays fixed. Speaker state is represented only by the persistent button highlight.
- When Bluetooth HFP/AirPods is available, Audio presents the route menu.
- Removed the duplicate interactive glass ButtonStyle from Audio, eliminating the faint second tap animation behind the control.
- AVAudioSession.currentRoute is now the source of truth; route selection is no longer optimistically changed before iOS commits it.
- Added AVAudioSession.routeChangeNotification observation so custom UI follows CallKit/Lock Screen route changes immediately.
- Route requests remain serialized off the main actor and ignore rapid overlapping requests.
- Route-change events now perform a bounded delayed in-place AVAudioEngine recovery if Core Audio temporarily stops the graph during a CallKit route transition.

Unchanged:
- CallKit identity/call lifecycle
- SMS UI/transport/notifications
- v19.19 app icon
- no Communication Notifications entitlement
- BLE and network audio protocol
- Android/Magisk
