# Credits & Attribution

This project is a derivative work. Full credit to the original authors.

---

## Windows RTL patch — shraga100

**Repository:** https://github.com/shraga100/claude-desktop-rtl-patch  
**License:** MIT Copyright (c) 2026 shraga100

This repo is a fork of shraga100's work. The core Windows patching mechanism
(`patch.ps1`, `install.ps1`, `src/rtl-core.js`, `src/rtl-payload.js`,
`tools/`) originates from that project. Modifications made in this fork:

- Vazirmatn variable font embedded for RTL text rendering
- Persian-specific detection improvements (RLM/LRM, ZWNJ notes, Persian numerals)
- macOS support added (see below)

---

## macOS patching approach — soguy

**Repository:** https://github.com/soguy/claude-desktop-rtl-mac  
**License:** MIT Copyright (c) 2025 soguy

The `patch-mac.sh` script in this repo was written independently but follows the
same design pattern established by soguy:

- Clone Claude.app rather than modifying it in place
- Embed fonts as base64 data URIs (required because Claude's CSP blocks external font URLs)
- Disable the Electron ASAR integrity fuse via `@electron/fuses`
- Re-sign with an ad-hoc codesign signature

soguy's project is the original and recommended Mac patch; this fork adapts the
approach for Persian (Vazirmatn font, updated detection) as part of a unified
Windows + macOS repo.

---

## Vazirmatn font — Saber Rastikerdar

**Repository:** https://github.com/rastikerdar/vazirmatn  
**License:** SIL Open Font License 1.1 (see `fonts/OFL.txt`)

Vazirmatn is a modern variable-weight Persian/Arabic typeface by Saber Rastikerdar,
released under the SIL OFL. The font file (`fonts/Vazirmatn[wght].woff2`) is
embedded as a base64 data URI in the built payload.

---

## Math formula isolation — Claude-UniMath / Davidi Bellaire

The LaTeX-in-RTL isolation technique (wrapping `$...$` segments in
`unicode-bidi: isolate` spans) was first introduced by
[Claude-UniMath](https://github.com/DavidiBellaire/Claude-UniMath)
by Davidi Bellaire.
