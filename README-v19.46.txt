Cellular iOS v19.46 — restored centered contact layout and sharp full background

Based directly on v19.45.

Contact detail layout
- Restores the centered circular contact photo and centered identity used before
  v19.45; the portrait is no longer placed in a left-aligned custom card.
- Restores the native inset-grouped Phone Numbers section and native number
  rows instead of the custom boxed number surface.
- Medium sheets use only a smaller centered portrait and tighter vertical
  spacing, so multiple phone numbers remain reachable without changing the
  visual structure.
- The contact detail remains a native scrolling List, so every number can
  scroll fully into view at either sheet detent.

Contact photo background
- Removes the blurred photo treatment, material veil, and gradient overlay.
- The contact image is now rendered sharp as the full contact-detail
  background.
- The navigation-bar background is transparent, allowing the same photo to
  continue through the top of the sheet without the previous cut-off seam.
- Contacts without a photo continue to use the semantic system grouped
  background in both light and dark mode.

Preserved from v19.45
- Message opens Cellular's existing composer over Contacts.
- Canceling the composer returns to Contacts; the Messages tab is selected
  only after a successful send.
- Call actions, multiple-number menus, and number normalization are unchanged.
- CallKit, BLE/UDP audio, SMS transport, notifications, icons, entitlements,
  Android, Magisk, and logs are unchanged.

Suggested checks
1. Open a contact at the medium detent and confirm the portrait is centered.
2. Confirm all available numbers appear as native Phone Numbers rows and the
   last row can scroll completely above the sheet edge.
3. Confirm the background photo is sharp and continues behind the top title
   and Done button with no dark horizontal cut-off.
4. Expand to the large detent and confirm the centered portrait grows without
   switching to a left-aligned layout.
5. Tap Message, cancel, and confirm Contacts remains selected; then send and
   confirm the conversation opens in Messages.
