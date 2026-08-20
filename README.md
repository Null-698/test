# J6 Handset — Low-Latency Audio (xtool / WSL)

This build keeps the working BLE call control, automatic audio lifecycle,
AUDIO_READY handshake, first-call mic watchdog, and automatic iOS audio-engine
restart. It changes only the Wi-Fi voice transport/buffering for lower delay.

## IMPORTANT: install both matching builds

The wire format changed from 20 ms / 320 bytes to 10 ms / 160 bytes.

Use:
- `src-patched-low-latency-audio.zip` on the J6 Android app.
- `J6Handset-LowLatency-xtool.zip` on the iPhone.

Do not mix this iPhone build with an older 20 ms Android build.

## Audio protocol

```text
8000 Hz
mono
PCM16 little-endian
10 ms packets
80 samples
160 bytes
100 packets/sec each direction

J6 -> iPhone UDP 41000
iPhone -> J6 UDP 41001
```

BLE is still control/signaling only. Call audio still travels over local Wi-Fi UDP.

## Latency changes

iPhone:
- AVAudioSession preferred I/O buffer: 20 ms -> 5 ms.
- Input tap request: about 20 ms -> about 5 ms.
- Network packetization: 20 ms -> 10 ms.
- Caller playback scheduled buffers: 4 -> 2.
- Caller playback prefill: 3 -> 2 packets.
- Caller jitter queue cap: 12 -> 5 packets.
- Actual iOS I/O/input/output latency is shown in the UI.

J6:
- Network packetization: 20 ms -> 10 ms.
- iPhone->cellular queue cap: 12 -> 4 packets (40 ms explicit queue).
- Playback prefill: 2 packets = 20 ms.
- AudioTrack initial silence prime: 100 ms -> 20 ms.
- Requests Android low-latency AudioTrack mode with automatic fallback.
- Allocates a safe AudioTrack capacity, then requests about 30 ms effective
  blocking-write buffer.
- Logs the actual AudioTrack buffer, performance mode, and underrun count.

The proven Samsung order remains unchanged:

```text
start AudioTrack
prime short silence
g_call_forwarding_enable=true
wait for Samsung reroute
create/start VOICE_DOWNLINK
start UDP relay
```

## Build/install iPhone with xtool

```bash
unzip J6Handset-LowLatency-xtool.zip
cd J6Handset-LowLatency-xtool
xtool dev
```

## Android

Replace the current `app/src` directory with the `src` directory from the
matching Android ZIP, then:

```bash
./gradlew assembleDebug
```

Install the resulting APK as before:

```bat
adb install -r path\to\app-debug.apk
```

## Test

Use a normal incoming call and talk back and forth. Do not make a priming call.

Watch:

```bat
adb logcat -c
adb logcat -s J6CallBridge J6BleControl J6LanRelaySvc GsmCallService GsmCallManager
```

Healthy startup should include:

```text
AUDIOTRACK_CONFIG frameMs=10 ...
RELAY_STARTED ... frameMs=10 trackFrames=... perf=...
```

Healthy steady-state stats should look roughly like:

```text
STATS tx=~500 rx=~500 ... q=0..3 ... underruns=0
```

Because packets are now 10 ms, the frame counters should increase at about
100/sec, so about 500 frames every 5 seconds.

### What to report after the test

Please paste one `AUDIOTRACK_CONFIG` line plus 2-3 `STATS` lines, and tell me:

1. whether speech delay feels much smaller;
2. whether either side crackles/cuts out;
3. the iPhone UI values for:
   - iOS I/O buffer
   - iOS input / output latency.

If `underruns` stays at zero and audio is clean, we can consider reducing one
more small buffer. If underruns climb or speech breaks up, we will increase the
smallest affected buffer slightly.


## Paced 10 ms mic transport

The 10 ms wire format is retained, but mic packets are no longer emitted in
AVAudioEngine callback bursts.

A dedicated pacer now:
- prebuffers 6 frames (60 ms);
- sends exactly one 160-byte UDP frame every 10 ms;
- caps queued mic audio at 10 frames (100 ms);
- drops the oldest frame only if the cap is exceeded.

The UI exposes `Mic pacer q / drops`.

Healthy values should be roughly:
- pacer q: a few frames;
- pacer drops: 0 or very small;
- J6 drops: near 0;
- J6 silence: near 0.

Use with the matching paced Android source package.


## Monotonic mic pacing

The previous 10 ms `DispatchSourceTimer` could lose effective send slots when
iOS coalesced/delayed a timer callback. The J6 showed this as:

```text
drops=0
q=0..1
silence steadily increasing
```

This build uses a monotonic 10 ms send timeline:

- a lightweight timer polls every 2 ms;
- the next send time is tracked with `DispatchTime.uptimeNanoseconds`;
- if iOS wakes one packet late, the pacer sends at most two due frames to
  catch back up;
- if it is delayed much longer, it re-phases rather than dumping a large
  backlog.

This keeps the long-term rate at ~100 packets/sec while preserving bounded
latency.

New diagnostics:

```text
Mic pacer q / drops
Pacer late / catch-up
```

A few catch-ups are normal. The J6 `silence` counter should stop climbing
rapidly.


## Real cellular outgoing ringback

Outgoing calls now start local iPhone audio during CONNECTING / DIALING.

Android runs a separate downlink-only relay while DIALING:

```text
cellular carrier ringback / busy / announcement
→ J6 VOICE_DOWNLINK
→ UDP 41000
→ iPhone speaker
```

No J6 AudioTrack and no `g_call_forwarding_enable` are used during DIALING,
so the iPhone microphone is not injected into cellular TX.

When Telecom changes to ACTIVE:

1. J6 stops the downlink-only service.
2. iPhone sends AUDIO_READY immediately if its mic stream is already verified.
3. Existing proven full-duplex J6LanRelayService starts.
4. Conversation continues on the same real VOICE_DOWNLINK path, now with
   iPhone mic -> cellular TX enabled too.


## Outgoing Hang Up UI fix

The call controls now explicitly treat these states as an ongoing call:

```text
NEW
CONNECTING
SELECT_PHONE_ACCOUNT
DIALING
ACTIVE
HOLDING
DISCONNECTING
```

During any of those states:
- the phone-number/Dial row is hidden;
- a large full-width red `Hang Up` button is shown.

Incoming `RINGING` still shows `Answer` and `Reject`.


## Immediate outgoing Hang Up fix

The previous UI still waited for the J6 to report `CONNECTING` / `DIALING`
before changing the call controls.

This build separates:

- `callState`: authoritative state received from J6 over BLE
- `uiCallState`: immediate state used to render the iPhone call controls

When `Dial` is tapped:

```text
uiCallState = DIALING
uiCallerID = entered number
→ Hang Up appears immediately
→ CMD|DIAL is sent
→ J6 state notifications take over when they arrive
```

If the BLE command write fails before the J6 call begins, the optimistic
DIALING UI returns to IDLE.


## J6A1 receiver-clocked audio transport

This build removes the app-timer mic pacer entirely.

Each 10 ms UDP packet now carries:
- stream/session id;
- sequence number;
- 8 kHz sample timestamp;
- 80 PCM16LE samples.

The receiver, not UDP arrival time, clocks playback:
- iPhone: AVAudioPlayerNode / device output clock;
- J6: AudioTrack / cellular injection clock.

Both sides use a small adaptive jitter buffer, sequence reordering, short
repeat+decay packet-loss concealment, stale-packet rejection, and tiny clock
recovery corrections instead of deleting/repeating whole 10 ms frames.

New iPhone diagnostics:
- Jitter q / target
- Network jitter
- PLC / late / stale
- Clock -/+ samples
- Wire bad / stream resets

The real cellular downlink ringback and ACTIVE conversation downlink share the
same packet format, so the DIALING -> ACTIVE transition automatically resets
by stream/session id.


## Always-on Bluetooth behavior

This build keeps `bluetooth-central` background mode and the stable
CoreBluetooth restoration identifier, and completes the restoration path.

Changes:
- Uses CoreBluetooth system auto-reconnect on iOS 17+.
- Restored peripherals immediately reattach their delegate and rediscover the
  J6 service/characteristics.
- A J6 reboot/link drop no longer falls back to a fragile scan-only loop.
- Pending/saved connections are preferred when Bluetooth becomes available.
- Normal app backgrounding/locking is supported.

Important iOS rule:
Swiping J6 Handset upward out of the app switcher is a USER FORCE QUIT.
iOS does not normally relaunch a force-quit CoreBluetooth app. Leave the app
backgrounded instead of swiping it away.

After an iPhone reboot, unlock the phone once. CoreBluetooth restoration can
then relaunch the app when a pending Bluetooth event occurs.


## Smooth J6 -> iPhone downlink fix

Compatible with the existing clock-recovered always-on Android build. Wire
format is unchanged.

Fixes:
- packet-boundary continuous 8 kHz -> iPhone-rate interpolation using one
  packet of look-ahead (removes a 100 Hz discontinuity/buzz source);
- packets get real late-arrival grace while AVAudioPlayerNode still has
  >=20 ms of audio queued;
- PLC is used only near a true underrun and is capped at two frames;
- startup/adaptive receive target is 50 ms / 40-80 ms;
- clock-recovery occupancy includes already-scheduled player audio;
- DIALING -> ACTIVE stream handoff flushes scheduled ringback cleanly.

No Android/uplink/UDP-wire changes.


# CallKit integration

This build adds native iPhone CallKit on top of the existing:
- background CoreBluetooth connection/restoration;
- real J6 cellular ringback;
- clock-recovered J6A1 UDP audio;
- smooth downlink renderer;
- immediate in-app outgoing Hang Up UI.

## Incoming calls

When BLE reports:

```text
STATE|RINGING|<number>
```

the app calls `CXProvider.reportNewIncomingCall`, so iOS presents the native
incoming-call UI on the Lock Screen / system call interface.

System **Answer**:
```text
CXAnswerCallAction
→ CMD|ANSWER
→ J6 cellular call
```

System **Decline/End**:
```text
CXEndCallAction
→ CMD|REJECT while RINGING
→ CMD|HANGUP otherwise
```

## Outgoing calls

The in-app Dial button now requests a `CXStartCallAction`. CallKit accepts the
transaction first, then the provider delegate sends:

```text
CMD|DIAL|<number>
```

J6 `CONNECTING/DIALING` is reported to CallKit as connecting, and J6 `ACTIVE`
is reported as connected.

Calls are included in iOS Recents.

## Audio-session coordination

Call audio no longer depends on SwiftUI being visible.

Apple's CallKit lifecycle owns `AVAudioSession` activation:
- Start/Answer configures `.playAndRecord` + `.voiceChat`.
- Actual UDP/AVAudioEngine call audio waits for
  `provider(_:didActivate:)`.
- If CallKit deactivates the session, the relay stops locally without trying
  to fight the system's audio-session ownership.
- When CallKit activates again, audio automatically restarts if the cellular
  call still needs it.

Outgoing DIALING still receives the real cellular downlink/ringback; it begins
as soon as CallKit activates the system call audio session.

## System mute

`CXSetMutedCallAction` is supported.

Mute does NOT stop the uplink clock. The iPhone continues sending correctly
timestamped 10 ms packets containing zero PCM while muted. This prevents the
J6 jitter buffer from interpreting mute as packet loss.

Holding/grouping are explicitly not supported because the current J6 BLE
protocol does not implement hold/resume.

## Background behavior

The CallKit/BLE/audio coordinator is owned by `J6HandsetApp`, not by
`ContentView`. This is required so a BLE notification that wakes the app in
the background can report an incoming call even when no SwiftUI screen is
currently active.

As before: do not swipe the app away from the iOS app switcher. A user force
quit prevents normal CoreBluetooth background restoration until the app is
opened again.


## xtool / Swift concurrency build fix

This revision fixes the Swift compiler errors where `CallKitCoordinator`
accessed the `@MainActor RelayController` from a nonisolated context.

Changes:
- `CallKitCoordinator` is `@MainActor`.
- `CXProviderDelegate` conformance is `@preconcurrency`.
- `CXProvider` delegate callbacks are explicitly delivered on `.main`.
- async CallKit completion handlers explicitly hop through
  `Task { @MainActor in ... }`.
- `J6HandsetApp` construction is explicitly `@MainActor`.
- deprecated `CXProviderConfiguration(localizedName:)` was replaced by
  `CXProviderConfiguration()`.

No BLE protocol, UDP wire format, jitter buffer, downlink smoothing, or J6
Android behavior changed.


## CallKit entitlement/background-mode fix

The previous build declared:

```text
UIBackgroundModes:
- audio
- bluetooth-central
```

but CallKit transactions require the app's VoIP background mode. This build
adds:

```text
- voip
```

Final array:

```text
audio
bluetooth-central
voip
```

The CallKit integration is also now fail-open:

- If `reportNewIncomingCall` fails, the real J6 GSM call is NOT rejected.
  The app keeps showing its in-app Answer/Reject controls.
- If `CXStartCallAction` is rejected, the app immediately falls back to
  `CMD|DIAL|...` over BLE.
- If CallKit Answer/End/Mute transactions fail, the equivalent existing
  BLE/audio action is performed directly.
- If `CXProvider` resets, the GSM call is kept alive and audio falls back to
  the previous app-managed AVAudioSession lifecycle.
- CallKit errors now show NSError domain + numeric code.

No J6 Android, UDP wire format, jitter buffer, downlink smoothing, or audio
packet changes are included.


# Telegram-style dual call UI

This revision keeps TWO representations of the same J6 cellular call:

1. `InAppCallView`
   - full-screen J6 Handset call UI;
   - incoming Answer/Decline;
   - outgoing/active End;
   - mute;
   - duration;
   - can be minimized into a persistent "Return to Call" banner.

2. CallKit/system call
   - same UUID tracked through `CXCallObserver`;
   - native incoming/system active-call surfaces;
   - system mute/end/audio-session actions;
   - provider icon button in native CallKit UI returns to J6 Handset;
   - included in Phone -> Recents after the call ends.

The coordinator persists the active CallKit UUID and reconciles it with
`CXCallController.callObserver`, making background/UI restoration more robust.

A previous fallback bug is also fixed: every new CallKit call explicitly
re-enables CallKit-managed audio, so one past CallKit failure cannot leave
future successful CallKit calls permanently in app-managed audio mode.

No J6 Android, BLE protocol, J6A1 UDP wire format, jitter-buffer, or
smooth-downlink algorithm changes are included.


# Contacts / caller metadata

This build adds optional iPhone Contacts integration.

On first foreground launch it requests Contacts access. Calls do not depend on
this permission.

Incoming/outgoing metadata flow:

```text
J6 phone number
→ canonical phone-number handle
→ CNContact phone-number predicate
→ conservative local/international suffix fallback
→ contact full name + preferred stored phone formatting + thumbnail
→ J6 in-app call screen
→ CXCallUpdate.localizedCallerName
→ CXCallUpdate.remoteHandle
```

Examples such as:

```text
989997248
+992989997248
```

can match the same stored contact when the subscriber digits agree and only a
short country/trunk prefix differs.

When a contact is found:
- CallKit receives the contact name through `localizedCallerName`;
- CallKit receives the canonical contact phone value as `remoteHandle`;
- the J6 in-app call screen shows the contact name, formatted number, and
  thumbnail image when available;
- the compact diagnostics UI and Return-to-Call banner show the contact name.

When no contact is found or permission is denied:
- calling continues normally;
- the formatted phone number is shown instead.

The app observes `CNContactStoreDidChange` and invalidates its caller-ID cache
when the user's contacts change.

No Android, BLE, UDP audio, J6A1 wire, jitter-buffer, CallKit call-state, or
audio-routing changes are included.


## Warning cleanup

This revision removes the two xtool warnings from `ContactResolver.swift`:

- `CNAuthorizationStatus.limited` is now explicitly handled in the switch.
- the immutable normalized phone `digits` variable now uses `let`.

No behavior, BLE, CallKit state, Contacts matching, or audio transport changes.


# Native-first CallKit fixes

This revision addresses observed device behavior:

## Incoming locked-screen caller ID
The BLE parser previously published `callState = RINGING` before assigning the
new `callerID`. The CallKit coordinator reacted synchronously to RINGING and
could therefore report the initial native call with an empty/Unknown handle.

Now:
1. BLE publishes caller ID first, then RINGING.
2. The Contacts lookup completes before the initial
   `reportNewIncomingCall`.
3. The first `CXCallUpdate` contains both the phone handle and
   `localizedCallerName` when a contact matches.

Late metadata updates remain supported for changes during a call.

## Native-first outgoing UI
The app no longer automatically covers a successful outgoing CallKit call
with its own full-screen call view. The system CallKit call owns automatic
presentation. The custom call screen is still available from the
"Return to Call" banner.

iOS does not expose a public API for a third-party app to command the full
Phone-style active-call screen to open on demand; system presentation remains
controlled by iOS.

## Branding cleanup
Visible app/provider branding was changed from `J6 Handset` to `Cellular`.
The optional in-app call screen no longer displays:
- "J6 Cellular"
- "J6 cellular call"
- "iOS CallKit registered"
- "System call active"

Its fallback identity is now simply "Unknown Caller", with neutral
"Incoming Call", "Calling…" and "Call" state text.

No Android, BLE protocol, UDP/J6A1 audio wire format, jitter-buffer,
ringback, or Samsung audio-routing behavior changed.


## Async CallKit cleanup

Replaced the deprecated/warning-producing callback form of
`CXProvider.reportNewIncomingCall` with the async/throws form:

```swift
try await provider.reportNewIncomingCall(with: uuid, update: update)
```

The existing fail-open behavior is preserved: if CallKit rejects the incoming
report, the actual J6 GSM call is not rejected and the in-app fallback remains
available.


## AirPods / Bluetooth call audio

Call audio no longer forces the iPhone speaker.

The session now uses two-way Bluetooth HFP routing for AirPods/headsets, does
not reconfigure the AVAudioSession after CallKit has activated it, and clears
any explicit speaker output override. When a single Bluetooth HFP call device
is available, it is preferred as the call input; iOS then pairs the matching
Bluetooth call output.

An `Audio route` diagnostics row shows the actual input/output route during
the call.

No Android, BLE, UDP wire, jitter-buffer, Contacts, or caller-ID changes.


## Bluetooth deprecation cleanup

Removed the deprecated `.allowBluetooth` fallback. The call audio session now
uses `.allowBluetoothHFP` directly for two-way AirPods/Bluetooth call audio.

No routing behavior change intended; this only removes the compiler warning.


## DIALING -> ACTIVE answer handoff smoothing

This revision changes ONLY the answer-time downlink transition.

When the J6 downlink sender session changes from outgoing DIALING/ringback to
ACTIVE/full-duplex:

1. the current ringback tail is faded down over about 8 ms;
2. old scheduled ringback is stopped/flushed;
3. the new ACTIVE sender session is rebuffered normally;
4. the first 20 ms of ACTIVE audio is faded in.

This smoothing is not used during normal steady-state conversation and does
not change:
- the normal jitter target;
- PLC behavior;
- clock recovery;
- AirPods/HFP routing;
- BLE/CallKit/Contacts;
- the J6 Android side;
- the J6A1 UDP wire format.

The intent is only to remove the click/buzz/distorted burst at the exact
DIALING -> ACTIVE transition.


## Answer handoff: ACTIVE fade-in removed

The first ACTIVE conversation audio is no longer faded in.

Final handoff behavior:

1. fade the DIALING/ringback tail down over about 8 ms;
2. stop/flush old ringback buffers;
3. rebuffer the new ACTIVE sender session;
4. play ACTIVE speech immediately at full level.

This keeps the anti-click ringback tail smoothing but avoids deliberately
softening the first phoneme spoken immediately after answer.


## iOS 26 Liquid Glass Phone-style UI

The in-app calling experience has been redesigned around public iOS 26
SwiftUI APIs:

- standard `TabView` for native iOS 26 Liquid Glass tab-bar behavior;
- Keypad as the default screen;
- 3x4 Phone-style dial pad with number/letter legends;
- long-press `0` inserts `+`;
- delete and green Call controls;
- contact-name lookup while dialing;
- full-screen in-app call UI with contact portrait/background;
- native-looking mute/audio/keypad control geometry;
- `AVRoutePickerView` for the real iOS audio-route picker;
- Liquid Glass custom controls via `GlassEffectContainer` and
  `.glassEffect(...interactive(), in: .circle)` on iOS 26;
- system-material fallback on iOS 17-25;
- all diagnostics moved to a Settings tab.

This is implemented with public SwiftUI/AVKit APIs and SF Symbols. No private
Phone.app assets or private frameworks are used.

The call backend is unchanged: BLE, CallKit, Contacts, AirPods/HFP routing,
J6A1 UDP audio, jitter/PLC/clock recovery, and DIALING->ACTIVE handoff logic
are untouched.


# System-first CallKit + native DTMF

Successful CallKit calls no longer open the custom full-screen call view.

Normal path:

```text
Liquid Glass dialer
→ CXStartCallAction / incoming CXProvider call
→ iOS system CallKit call is authoritative
→ app remains on Keypad/Settings with only a compact glass call strip
```

The full custom `InAppCallView` remains only as a fail-open fallback if
CallKit itself becomes unavailable.

## Native CallKit keypad / DTMF

`CXCallUpdate.supportsDTMF = true`.

When the user enters a digit from the native CallKit in-call keypad, CallKit
delivers `CXPlayDTMFCallAction`. The app forwards:

```text
CMD|DTMF|<digits>
```

over the existing BLE control characteristic to the J6. Android Telecom then
injects each DTMF digit into the live cellular call.

CallKit handles local keypad tone feedback. The app forwards the digits only.

No audio transport, jitter, answer-handoff, Contacts, AirPods, or UDP wire
changes are included.


# Full in-app call UI + CallKit in parallel

This revision restores a full-screen in-app call interface for every active
call while keeping the actual CallKit call registered and authoritative.

Normal behavior:

```text
Liquid Glass dialer
→ Dial / incoming call
→ real CallKit call exists in iOS
→ full in-app call UI opens
→ user may minimize it back to the dialer
→ compact active-call strip remains
→ tap the strip to reopen the full in-app call UI
```

The in-app call UI is functional:
- caller/contact name and formatted number;
- contact thumbnail / blurred contact background;
- live call duration;
- incoming Accept / Decline;
- Mute / Unmute through CallKit;
- native AVRoutePicker for AirPods/speaker/audio route;
- full in-call DTMF keypad using the same `CMD|DTMF|...` BLE path;
- End Call through CallKit;
- minimize / restore.

The real CallKit call still provides:
- Lock Screen/system call surfaces;
- Recents;
- system mute/end actions;
- AirPods/AVAudioSession ownership;
- native CallKit keypad and DTMF;
- background/system call state.

The custom UI uses public iOS 26 Liquid Glass APIs and SF Symbols. It does not
depend on private Phone.app frameworks or private assets.


# Reference-matched iOS 26 Phone UI

This build replaces the earlier generic Liquid Glass styling with geometry and
visual treatment derived from the supplied real Phone screenshots.

## Dialer

The supplied 1320×2868 screenshots correspond to 440×956 points at @3x.

Measured geometry used by `NativeDialerView`:

- digit centers X: approximately 108 / 220 / 332 pt
- digit centers Y: approximately 311 / 419 / 527 / 635 pt
- digit circle diameter: approximately 88.5 pt
- call-button center Y: approximately 748.5 pt

The digit buttons deliberately do **not** use Liquid Glass. The reference Phone
screens show restrained filled circles. Light/dark colors, outlines and light
mode shadows are handled dynamically.

The bottom navigation uses native SwiftUI `TabView`. On iOS 18+ the trailing
Search item uses `TabRole.search`, allowing iOS 26 to render the native pinned
search treatment / Liquid Glass tab bar instead of drawing a fake replica.

## Active call

The custom call screen follows the supplied active Phone screenshot:

- compact duration + caller identity at the top;
- no large contact poster/avatar;
- six controls anchored low:
  Speaker / FaceTime(disabled) / Mute
  More / End / Keypad;
- subtle clear Liquid Glass circles on iOS 26;
- real AVRoutePicker hit target behind the Speaker control;
- live CallKit mute/end;
- real BLE DTMF keypad;
- More -> Minimize Call.

The connected timestamp now belongs to `CallKitCoordinator`, so minimizing and
reopening the custom call view does not reset the timer.

## Failed call

An outgoing call that ends before it reached ACTIVE now preserves a native-style
Call failed screen with:

- Call failed
- formatted destination
- Cancel
- Call Back

Call Back starts the same real CallKit/J6 outgoing flow again.

No UDP audio, jitter/PLC, AirPods audio-session policy, answer handoff, Contacts
matching, or Android protocol behavior was changed.


# iOS 26 SDK-enforced native Liquid Glass revision

This project is intentionally iOS 26-only:

```swift
// swift-tools-version: 6.2
platforms: [.iOS(.v26)]
```

It uses iOS 26 SwiftUI APIs directly:
- native `TabView` / `Tab(role: .search)`
- `.tabBarMinimizeBehavior(.never)`
- `.buttonStyle(.glass)`
- `.buttonStyle(.glass(.clear))`
- `.buttonStyle(.glassProminent)`
- `GlassEffectContainer`

There is no iOS 18 navigation fallback in this build.

`Info.plist` explicitly sets:

```xml
<key>UIDesignRequiresCompatibility</key>
<false/>
```

If this source fails to compile because the iOS 26 APIs are unknown, the
installed xtool Darwin SDK was generated from an older Xcode XIP. Regenerate it
from Xcode 26.x, then rebuild.

Run before building:

```bash
./check-ios26-sdk.sh
```

## DTMF

The in-app keypad no longer calls BLE directly. It requests a real
`CXPlayDTMFCallAction(.singleTone)`. CallKit therefore provides the same local
DTMF feedback as the native system keypad, and the provider delegate forwards
the digit to the J6.

The matching Android patch disables the J6's own local Telecom DTMF tone while
leaving network DTMF signaling enabled. Install both matching patches for the
distortion fix.


## Compile fix: Liquid Glass selected-state control

Swift cannot type-erase different concrete PrimitiveButtonStyle types through:

```swift
.buttonStyle(selected ? .glassProminent : .glass(.clear))
```

The selected and unselected buttons are now emitted as separate ViewBuilder
branches, so each `.buttonStyle(...)` has its own concrete type.

No audio, BLE, DTMF, CallKit, tab-bar, or Android behavior changed.


# Modern Glass UI revision

This revision intentionally stops trying to clone Phone.app / CallKit pixel for
pixel.

Tab bar is now exactly:

- Keypad
- Settings

Removed from the tab bar:

- Calls
- Contacts
- Search

The former Contacts / Bluetooth / audio controls are consolidated into Settings:

- Contacts
- J6 Connection
- Call Audio
- Diagnostics

The modern dialer uses:

- adaptive system background
- restrained gradients
- a single glass number/contact card
- clear Liquid Glass keypad buttons
- prominent green Liquid Glass call button
- contact-name resolution
- long-press 0 for +
- redial
- delete

The modern in-app call UI is intentionally app-native rather than a Phone clone.
Every visible control is functional:

- Minimize
- Mute / Unmute
- Audio route picker
- DTMF keypad
- End Call
- Answer / Decline

DTMF still goes through `CXPlayDTMFCallAction`.
CallKit remains authoritative underneath.
No UDP/audio/CallKit/J6 transport behavior was changed.
