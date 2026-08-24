Cellular iOS v19.44 — contact bottom sheet and reliable dialing

Based directly on v19.43.

Contact presentation
- Selecting a contact now opens Cellular's custom contact detail in the same
  native bottom-sheet style used by the USSD result.
- The sheet starts at the medium detent and can expand to the large detent.
- Contact details no longer push a full page onto the Contacts navigation stack.
- The sheet keeps the custom photo, name, organization, Call, Message, labeled
  phone-number rows, multiple-number menus, native Done action, and system
  light/dark colors from v19.43.

Reliable contact actions
- Call and Message are queued by the contact sheet and executed only after the
  sheet has finished dismissing, avoiding presentation and navigation races.
- Contact phone values are normalized to a dialable number before entering the
  existing CallKit path. Formatting characters such as spaces, parentheses,
  and hyphens can no longer make BLE reject the call silently.
- Calling no longer changes to the Keypad tab. A successful request presents
  the existing in-app call screen directly over Contacts.
- Message still opens Cellular's own composer with the recipient prefilled.

Unchanged
- Contacts stay fully custom; ContactsUI was not restored.
- The contact list, search, avatar cache, background contact loading, CallKit
  state machine, BLE/UDP audio, SMS transport, notifications, icon assets,
  entitlements, Android, Magisk, and logs are unchanged.

Suggested checks
1. Select a contact and confirm the detail rises from the bottom at medium size.
2. Drag the contact sheet between medium and large, then dismiss it with Done.
3. Call a number stored with spaces, hyphens, or parentheses and confirm the
   call screen appears and the carrier call starts.
4. Test Call and Message on contacts with one number and multiple numbers.
