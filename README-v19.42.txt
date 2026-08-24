Cellular iOS v19.42 — stable Contacts tab and action routing

Based directly on v19.41.

Contacts tab workaround
- Contacts is now a real selected tab instead of a modal picker action.
- The tab uses the native iOS List, navigation title, search field, row reuse,
  separators, contact photos, system colors, and accessibility behavior.
- Contact data is fetched once off the main thread and each row has a stable
  contact identifier. Search uses a short cancellable debounce.
- Apple's CNContactPickerViewController is no longer used, so Cancel cannot
  return to a previously selected tab.
- Selecting a row opens one full-screen Apple CNContactViewController directly.
  This removes the picker-dismiss/detail-present sequence that caused the
  visible jump.

Call and Message fixes
- The selected contact is refetched using
  CNContactViewController.descriptorForRequiredKeys() before its card opens.
- Phone-number property taps still suppress Apple's default action and now call
  immediately through Cellular's existing CallKit path.
- The Message bar item is installed after ContactsUI configures its navigation
  item and is reapplied during appearance, so ContactsUI cannot replace it.
- Message now requests Cellular's existing prefilled SMS composer immediately.
- Call and Message no longer depend on a second full-screen cover's onDismiss
  callback, which was the shared failure point in v19.40/v19.41.

Public-API boundary
- Apple does not expose its complete Contacts list as an embeddable tab.
- The permanent list therefore uses only standard public SwiftUI controls; the
  detail card remains Apple's genuine ContactsUI controller.
- No cloned contact-card UI, private API, custom glass, or custom transition was
  added.

Unchanged
- The v19.41 Swift 6 @preconcurrency ContactsUI fix is preserved.
- No CallKit state-machine, SMS transport, BLE, UDP/audio, Android, Magisk,
  notification, app-icon, logging, or entitlement behavior changed.

Suggested checks
1. Select Contacts and confirm the tab remains selected.
2. Search and scroll the list, then select a contact and confirm one smooth
   presentation of Apple's contact card.
3. Tap a phone-number row and confirm Cellular starts the call.
4. Tap Message, choose a labeled number if needed, and confirm Cellular opens
   its composer with the recipient prefilled.
5. Close the contact card and confirm the Contacts list remains visible.
