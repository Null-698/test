Cellular iOS v19.47 — fixed v19.44 contact layout and readable photo backdrop

Based directly on v19.46.

Stable v19.44 contact layout
- Restores the v19.44 contact-detail measurements and structure exactly:
  centered 112-point circular portrait, fixed 16-point header spacing,
  fixed 12-point vertical padding, 68-point Call/Message actions, and native
  inset-grouped phone-number sections.
- Removes the height-based compact/large layout switch introduced after
  v19.44. Dragging the sheet between medium and large no longer changes the
  portrait size, action size, spacing, or number layout.
- The native List simply gains more visible space as the sheet expands, so
  numbers and other details do not jump during the detent transition.

Readable full-background contact photo
- Restores blur to the background photo only; the centered circular portrait
  remains clear and sharp.
- The background uses scaled-to-fill rendering plus 16 percent overscan before
  blur, preventing narrow contact images from leaving empty side bands.
- A semantic system-background contrast layer adapts to light and dark mode so
  the contact name, actions, section labels, phone numbers, title, and Done
  button remain readable.
- The background still extends beneath the transparent navigation bar and
  covers the complete contact sheet.
- Contacts without a photo continue to use the normal semantic grouped system
  background.

Preserved
- Message opens Cellular's composer over Contacts; cancel returns to Contacts,
  and Messages is selected only after a successful send.
- Contact Call actions, multiple-number menus, and number normalization remain
  unchanged.
- CallKit, BLE/UDP audio, SMS transport, notifications, icons, entitlements,
  Android, Magisk, and logs are unchanged.

Suggested checks
1. Drag a contact sheet repeatedly between medium and large; confirm the
   portrait, buttons, number rows, and spacing keep exactly the same size.
2. Test portrait and landscape contact photos; confirm the blurred background
   reaches both side edges and the top of the sheet.
3. Test the same contacts in light and dark mode and confirm every label and
   phone number is readable.
4. Confirm the foreground portrait stays sharp while only the background is
   blurred.
5. Test Call and Message, including canceling a message and sending one.
