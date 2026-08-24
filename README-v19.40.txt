Cellular iOS v19.40 — native ContactsUI flow

Based directly on v19.39.

Added
- Contacts is now available from the main iOS 26 tab bar.
- Selecting Contacts presents Apple's full-screen CNContactPickerViewController.
- The contact list, search field, contact photos, names, and selection behavior
  are rendered by ContactsUI rather than recreated in SwiftUI.
- Selecting a person opens Apple's CNContactViewController contact card.
- Phone labels and the rest of the contact details remain system-rendered.
- The Contacts privacy description now also explains contact-based Call and
  Message selection.

Cellular action routing
- Tapping a phone-number property suppresses the default Phone-app action and
  starts the call through Cellular's existing CallKitCoordinator path.
- The system contact card's built-in action buttons are disabled so Call or
  Message cannot accidentally escape to Apple's Phone or Messages apps.
- A native navigation-bar Message action opens Cellular's SMS composer.
- For contacts with multiple phone numbers, Message presents a native UIKit
  menu containing the localized phone label and number.
- The SMS composer now supports an app-internal prefilled-recipient request.
- Incoming calls dismiss the ContactsUI flow so the call screen is not hidden.

Deliberately not added
- No cloned Contacts list, search UI, contact card, avatar style, or animation.
- No Favorites screen or custom favorites database.
- No Communication Notifications capability or entitlement.
- No Android, Magisk, BLE protocol, UDP/audio, CallKit state-machine, Recents,
  contact-cache, notification, or app-icon changes.

Suggested checks
1. Tap Contacts and confirm Apple's searchable contact picker appears.
2. Select a contact and confirm the native contact card and phone labels appear.
3. Tap a phone number and confirm Cellular starts the call.
4. Open Message on a one-number contact and confirm the recipient is prefilled.
5. Open Message on a multi-number contact and confirm the native number menu.
6. Cancel the picker/detail and confirm the previously selected tab remains.
