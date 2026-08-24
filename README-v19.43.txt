Cellular iOS v19.43 — fully custom Contacts experience

Based directly on v19.42.

Removed
- CNContactPickerViewController is no longer used.
- CNContactViewController is no longer used.
- ContactsUI delegates, @preconcurrency delegate bridges, property-action
  interception, injected navigation buttons, chained full-screen covers, and
  ContactsUI presentation timing are all removed from the active source.

Cellular-owned Contacts UI
- Contacts remains a real permanent tab.
- The contact list uses a standard SwiftUI List with stable identifiers, native
  row reuse, system separators, a native search field, contact photos, names,
  and the primary labeled phone number.
- Selecting a contact pushes Cellular's own detail screen inside the Contacts
  tab's existing NavigationStack. There is no modal presentation or Cancel
  bounce.
- The detail screen uses system grouped surfaces and semantic colors so its
  text, actions, menus, and rows remain readable in light and dark mode.
- The detail screen shows the contact photo, name, organization, and every
  labeled phone number.

Reliable actions
- Tapping any phone-number row invokes Cellular's existing CallKit path
  directly.
- The Call action invokes the same direct CallKit path.
- The Message action invokes Cellular's existing prefilled SMS composer
  directly.
- Contacts with multiple numbers get an app-owned native menu showing each
  localized phone label and number for Call and Message.
- Contacts with one number act immediately without a menu.
- No action waits for a sheet/cover dismissal callback and no action can escape
  to Apple's Phone or Messages apps.

Performance
- Contact enumeration and detail loading stay off the main actor.
- List rows use stable contact identifiers and the existing decoded-avatar
  cache.
- Search operates on a precomputed index with a short cancellable debounce.
- A full-resolution contact photo is loaded only for the selected detail.

Unchanged
- Contacts permission and ContactResolver behavior are preserved.
- No CallKit state-machine, SMS transport, BLE, UDP/audio, Android, Magisk,
  notification, app-icon, logging, or entitlement behavior changed.

Suggested checks
1. Open Contacts, scroll and search, and confirm the list stays smooth.
2. Select a contact and confirm the detail pushes normally with a Back button.
3. Tap each phone-number row and confirm Cellular starts the call.
4. Test the Call and Message actions on contacts with one and multiple numbers.
5. Return from the detail and confirm the Contacts list/search state remains.
