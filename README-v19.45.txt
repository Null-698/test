Cellular iOS v19.45 — compact contact sheet, photo backdrop, and local composer

Based directly on v19.44.

Contact sheet layout
- The medium contact sheet now uses a compact header instead of spending most
  of its height on the large portrait and grouped-list padding.
- Labeled phone-number rows move directly beneath Call and Message, allowing
  typical contacts with multiple numbers to remain visible at medium height.
- The complete detail remains vertically scrollable, with bottom padding, so
  the final number can always scroll fully above the sheet edge.
- Long formatted numbers stay on one line and scale down slightly when needed.
- The large detent retains a roomier portrait header.

Contact photo background
- A contact photo now fills the detail background behind the content.
- The backdrop is decoded off the main actor, downsampled, cached, softly
  blurred, and covered with native adaptive material plus semantic system-color
  shading for readable light and dark mode.
- The clear circular contact photo remains visible in the foreground header.
- Contacts without a photo retain the normal system grouped background.

Message routing
- Message from a contact now presents Cellular's existing composer directly
  over Contacts without selecting the Messages tab first.
- Canceling or swiping the composer away returns to the same Contacts list and
  search position.
- Only a successful Send requests the conversation and changes to Messages.
- The existing transport, outgoing-message record, and conversation-opening
  behavior are reused unchanged.

Unchanged
- Contact calling and formatted-number normalization from v19.44 are preserved.
- Contacts remain fully custom; ContactsUI was not restored.
- CallKit, BLE/UDP audio, SMS transport, notifications, icons, entitlements,
  Android, Magisk, and logs are unchanged.

Suggested checks
1. Open contacts with one, two, and several numbers at the medium detent.
2. Confirm the final phone row can be shown completely without clipping.
3. Expand to large and verify the larger portrait layout and photo backdrop.
4. Tap Message and cancel; confirm Contacts remains selected at the same place.
5. Send a message; confirm the app then opens that conversation in Messages.
