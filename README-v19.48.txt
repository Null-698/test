Cellular iOS v19.48 — dimmer contact backdrop and unclipped phone numbers

Based directly on v19.47.

Phone-number visibility
- Keeps the native v19.44 List, sections, centered identity, and interaction
  structure.
- Uses one fixed compact layout at both medium and large detents: an 88-point
  centered circular portrait, fixed 12-point spacing, fixed 8-point header
  padding, and fixed 60-point Call/Message actions.
- There is still no height-dependent layout branch, so dragging between sheet
  sizes cannot resize or rearrange the portrait, buttons, or phone numbers.
- Adds a native 32-point bottom scroll-content margin so the final number row
  can move completely above the rounded sheet edge instead of being clipped.
- The fixed compact measurements leave more phone-number rows visible when the
  sheet first opens at medium height.

Dimmed readable background
- Keeps the full-bleed, scaled, overscanned, and blurred contact-photo
  background from v19.47.
- Strengthens the adaptive system-background contrast veil and adds a subtle
  dark dimming layer so the photo remains visible without competing with the
  title, labels, actions, or phone numbers.
- The sharp centered circular portrait is unaffected.
- Contacts without a photo retain the normal semantic grouped background.

Preserved
- Message opens Cellular's composer over Contacts; cancel returns to Contacts,
  and Messages is selected only after a successful send.
- Contact Call actions, multiple-number menus, and number normalization remain
  unchanged.
- CallKit, BLE/UDP audio, SMS transport, notifications, icons, entitlements,
  Android, Magisk, and logs are unchanged.

Suggested checks
1. Open a contact with one, two, and several numbers at medium height.
2. Confirm typical multiple-number contacts show more rows immediately and the
   final row can always scroll completely clear of the bottom edge.
3. Drag repeatedly between medium and large and confirm the portrait, action
   buttons, spacing, and number rows do not resize or jump.
4. Test light and dark mode and confirm the dimmed photo never makes text or
   phone numbers unreadable.
5. Confirm the background covers the top and both sides while the foreground
   contact portrait remains sharp.
