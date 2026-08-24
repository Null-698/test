Cellular iOS v19.41 — ContactsUI Swift 6 isolation fix

Based directly on v19.40.

Fixed
- The CNContactPickerDelegate and CNContactViewControllerDelegate conformances
  now use Swift's @preconcurrency bridge for legacy Objective-C delegate
  protocols whose requirements are not annotated for MainActor isolation.
- This removes the ConformanceIsolation warnings that become errors when the
  project is compiled in Swift 6 language mode.

Actor-safety behavior
- Both UIKit coordinator classes remain @MainActor.
- Their delegate callbacks, closures, contact selection, view dismissal, Call
  routing, and Message routing remain on the main actor.
- The callbacks were not made nonisolated, so ContactsUI objects and UI state
  are not passed through unsafe cross-actor tasks.

Unchanged
- No Contacts interface, contact-detail, Call, Message, tab, menu, dark/light
  mode, notification, CallKit, BLE, UDP/audio, Android, Magisk, or entitlement
  behavior changed.

Suggested check
1. Rebuild with the same xtool/Swift toolchain and confirm the two
   ConformanceIsolation warnings from NativeContactsFlow.swift are gone.
