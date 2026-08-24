iOS Stage 2 v19.8 - Fresh Contacts / No Contact Cache

- Removes ContactResolver contact metadata/image cache entirely.
- Every contact resolve queries CNContactStore fresh.
- SMS inbox and conversation rows refresh when CNContactStoreDidChange fires.
- Requests thumbnailImageData and imageData in the same lookup.
- No Android or Magisk changes required.
