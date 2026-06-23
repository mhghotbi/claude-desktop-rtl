<div align="center">

# Claude Desktop RTL Patch

**Proper Persian & Arabic (right-to-left) support for Claude Desktop on Windows and macOS.**

Auto-detects RTL text, aligns direction in real time, and renders Persian text in Vazirmatn — without breaking English or code blocks.

[فارسی](README.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6.svg)](#-requirements)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#-macos)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#-requirements)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#-contributing)
[![GitHub stars](https://img.shields.io/github/stars/mhghotbi/claude-desktop-rtl-patch?style=social)](https://github.com/mhghotbi/claude-desktop-rtl-patch/stargazers)

</div>

---

## ✨ What it does

- **Auto-detects RTL text** in Claude's responses and the input box, and aligns the direction in real time, even while a reply is still streaming.
- **Renders Persian text in Vazirmatn** — a modern variable-weight font designed for Persian and Arabic, embedded as a data URI so it works without internet access.
- **Handles code, math formulas, and tables** — code blocks and LaTeX (`$x^2$`, `$$…$$`) stay left-to-right inside Persian, and Persian tables read right-to-left.
- **Fixes the broken window UI on RTL systems** (see the note below).
- **Backs up every file it touches**, with one-click restore and automatic rollback if anything goes wrong.
- **Stays applied across updates** (optional), via a desktop shortcut or a background auto-updater.

> [!NOTE]
> On a Windows system whose display language is set to Persian/Arabic, Claude Desktop's entire window UI flips to RTL on its own. This is a pre-existing bug, not caused by the patch. It pushes the title-bar window controls (minimize / maximize / close) on top of Claude's own settings and navigation buttons, hiding them, and sends the preview window to the far left. The patch fixes this by forcing the window chrome back to LTR, without affecting the direction of the chat text itself.

---

## 🚀 Quick install — Windows

Open **Windows PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/mhghotbi/claude-desktop-rtl-patch/main/install.ps1 | iex
```

A UAC prompt will appear. Click **Yes** to grant administrator privileges, then choose **1. Install** from the menu.

> [!TIP]
> Prefer not to pipe to `iex`? Download `patch.ps1` from the repo, right-click it, and choose **Run with PowerShell**.

---

## 🍎 macOS

The Mac version creates a separate **Claude-RTL.app** in `~/Applications` — the original app is never touched.

**Requirements:** Node.js (from [nodejs.org](https://nodejs.org/)) and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/mhghotbi/claude-desktop-rtl-patch
cd claude-desktop-rtl-patch
bash patch-mac.sh
```

Choose **1. Install** from the menu. Then open **Claude RTL** from `~/Applications`.

> [!NOTE]
> On macOS the patch clones Claude.app rather than modifying it in-place, so no certificate manipulation is needed. Ad-hoc code signing is used. The original Claude.app continues to work normally alongside Claude-RTL.app.

---

## 📋 Requirements

### Windows

| Requirement | Notes |
| :--- | :--- |
| **Windows 10 / 11** | With Claude Desktop installed ([download](https://downloads.claude.ai/releases/win32/ClaudeSetup.exe)) |
| **Node.js** | `npx` must be on your PATH ([nodejs.org](https://nodejs.org/)), used to repack the app archive |
| **Administrator** | The installer elevates automatically via UAC |

### macOS

| Requirement | Notes |
| :--- | :--- |
| **macOS** | With Claude Desktop installed ([download](https://claude.ai/download)) |
| **Node.js** | `npx` must be on your PATH ([nodejs.org](https://nodejs.org/)) |
| **Xcode CLI tools** | For `codesign`: `xcode-select --install` |

> [!IMPORTANT]
> On Windows, use the built-in **Windows PowerShell** (the blue window), not PowerShell 7 (`pwsh`). See troubleshooting below.

---

## 🎛️ Menu options

### Windows (`patch.ps1`)

| # | Option | What it does |
| :---: | :--- | :--- |
| **1** | Install Smart RTL Patch | Backs up the originals and injects RTL support |
| **2** | Restore Original State | Reverts every change the patch made |
| **3** | Create 'Quick Update' Shortcut | Adds a desktop shortcut for one-click re-patching |
| **4** | Enable Auto Re-Patch | Installs a background watcher that re-patches after each Claude update |
| **5** | Disable Auto Re-Patch | Removes that background watcher |
| **6** | Exit | Close the patcher |

### macOS (`patch-mac.sh`)

| # | Option | What it does |
| :---: | :--- | :--- |
| **1** | Install | Clones Claude.app and injects RTL support → `~/Applications/Claude-RTL.app` |
| **2** | Restore | Removes `Claude-RTL.app` (original Claude.app untouched) |
| **3** | Exit | Close the patcher |

---

## 🔄 Keeping the patch applied (Windows)

Claude Desktop updates often, and each update overwrites the patch. Two optional features keep it effortless:

- **Quick Update shortcut (option 3):** a desktop shortcut named **"Update Claude RTL"**. Double-click it to silently fetch and re-apply the latest patch.
- **Auto-updater (option 4):** a lightweight Windows scheduled task that detects when a new `claude.exe` version launches, re-applies the patch automatically, and shows a notification when it's done.

On macOS, simply re-run `bash patch-mac.sh` after a Claude Desktop update.

---

## 🗑️ Uninstall

**Windows:** Run the script and choose **2. Restore Original State**. This restores all original files from backup and removes the self-signed certificate from your Windows certificate store. If you enabled the auto-updater, choose **5. Disable Auto Re-Patch** as well.

**macOS:** Run `bash patch-mac.sh restore` (or choose option 2 from the menu). The original Claude.app is untouched.

---

## 🛠️ Troubleshooting

**"Node.js (npx) is required":** Install Node.js from [nodejs.org](https://nodejs.org/) and reopen your terminal.

**Claude won't start after patching (Windows):** Run the script again, choose **2 (Restore)**, then **1 (Install)**.

**Claude updated and the patch broke (Windows):** Run the "Update Claude RTL" shortcut, or use the auto-updater. To fix it manually, delete any `.bak` files in the Claude app directory and run the installer again.

**`Import-Module … The member AuditToString is already present`:** You ran the command in **PowerShell 7 (`pwsh`)**, which has a known bug that breaks the patch. Use the built-in **Windows PowerShell** instead:

1. Press **Win + R**, type `powershell`, and press **Enter**. This opens the classic **blue** Windows PowerShell window (not the black `pwsh` one).
2. Paste the install command and run it.

**macOS — codesign fails:** Make sure Xcode Command Line Tools are installed (`xcode-select --install`) and that Terminal has Full Disk Access in **System Settings → Privacy & Security → Full Disk Access**.

---

<details>
<summary><b>🔍 How it works (technical)</b></summary>

### JavaScript payload

The detection logic lives in [`src/rtl-core.js`](src/rtl-core.js) (pure, unit-tested, DOM-free) and [`src/rtl-payload.js`](src/rtl-payload.js) (DOM layer + Vazirmatn font injection). `tools/build-payload.ps1` assembles them:

1. Inlines `rtl-core.js` into `rtl-payload.js` at `/*__RTL_CORE__*/`
2. Base64-encodes `fonts/Vazirmatn[wght].woff2` and injects it as a `@font-face` data URI at `/*__FONT_CSS__*/` (Claude's CSP blocks external font URLs)
3. Writes `dist/rtl-payload-built.js` (used by `patch-mac.sh`) and splices the result into `patch.ps1`

### Windows patching

Claude Desktop is a **digitally signed** Electron app, so editing its UI code breaks the integrity checks. The Windows patch works in three phases, all atomic, with automatic rollback on failure:

**Phase 1, ASAR injection.** Claude's UI lives inside `app.asar`. The script extracts it with `npx @electron/asar`, prepends the RTL-detection payload to the renderer files (and forces the window UI to LTR in the main process), and repacks the archive.

**Phase 2, hash replacement in `claude.exe`.** The original ASAR hash is stored as an ASCII string inside `claude.exe`. The script does a byte-level search-and-replace to update it. If the format ever changes, it falls back to disabling the Electron integrity fuse.

**Phase 3, certificate swap in `cowork-svc.exe`.** This service verifies `claude.exe` against Anthropic's embedded certificate. The script replaces it in-place with a self-signed one, re-signs both binaries, adds the new certificate to the Windows trusted root store, and then wipes the private key.

### macOS patching

The macOS approach is simpler — no certificate manipulation required:

1. **Clone** Claude.app to `~/Applications/Claude-RTL.app`
2. **Inject** the RTL payload into renderer files in the ASAR archive
3. **Disable** the ASAR integrity fuse via `@electron/fuses`
4. **Sign** with an ad-hoc signature (`codesign --force --deep --sign -`)

All original files are backed up as `.bak` next to the originals before anything changes.

</details>

<details>
<summary><b>🔐 Security & verification (Windows)</b></summary>

`install.ps1` verifies an **RSA-4096 signature** over `patch.ps1` before running it. A compromised GitHub repo alone is **not** enough to ship malicious code; the attacker would also need the maintainer's offline private key.

**Public-key fingerprint (SHA-256):**

```
e5:a8:55:e0:df:e1:24:7e:51:87:21:5f:c4:50:68:64:da:48:24:58:46:b1:1d:02:e4:1f:71:46:aa:df:8a:b3
```

To double-check, recompute the fingerprint of the key embedded in `install.ps1` and confirm it matches:

```powershell
$content = Invoke-RestMethod "https://raw.githubusercontent.com/mhghotbi/claude-desktop-rtl-patch/main/install.ps1"
if ($content -match "ExpectedPubKey\s*=\s*'([A-Za-z0-9+/=]+)'") {
    $bytes = [Convert]::FromBase64String($matches[1])
    $hash  = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    ([BitConverter]::ToString($hash)).Replace('-', ':').ToLower()
}
```

A mismatch means the embedded key was swapped. **Do not proceed**, and report it as a security issue.

To audit a release without installing:

```powershell
git clone https://github.com/mhghotbi/claude-desktop-rtl-patch
cd claude-desktop-rtl-patch
powershell -ExecutionPolicy Bypass -File tools\verify-signature.ps1
```

</details>

---

## ⚠️ Disclaimer

> [!CAUTION]
> This patch modifies Claude Desktop's binaries (Windows) or creates a modified copy (macOS). The Windows version replaces Anthropic's code-signing certificate inside `cowork-svc.exe` with a self-signed one, adds that certificate to your Windows **trusted root store**, and bypasses the app's integrity verification.

By installing, you accept that:

1. **You use it at your own risk.** The authors take no responsibility for system damage, data loss, or instability.
2. **Modifying the app may not align with Anthropic's Terms of Service.** It's worth reviewing them and using your own judgment.
3. **You trust this repository.** Running `irm | iex` as Administrator (Windows) or `bash patch-mac.sh` (macOS) executes code with elevated privileges, so always verify the source.
4. **It's temporary.** Claude updates overwrite the patched files, so re-run the installer (or use the auto-updater) after each update.
5. **It's a stopgap** until Anthropic adds native RTL support. Please request that feature through official channels.

---

## 🤝 Contributing

This project is open source under the **MIT** license. Contributions that improve RTL accuracy are very welcome, and PRs are open. 🙏

---

## 🙏 Credits

This project is a derivative work. Full attribution in [CREDITS.md](CREDITS.md).

| Project | Author | What was used |
| :--- | :--- | :--- |
| [claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch) | shraga100 | Original Windows RTL patch — this repo is a fork |
| [claude-desktop-rtl-mac](https://github.com/soguy/claude-desktop-rtl-mac) | soguy | macOS patching design (clone + fuse disable + ad-hoc sign) and font-as-base64 approach |
| [Vazirmatn](https://github.com/rastikerdar/vazirmatn) | Saber Rastikerdar | Persian/Arabic variable font (OFL license) |
| [Claude-UniMath](https://github.com/DavidiBellaire/Claude-UniMath) | Davidi Bellaire | LaTeX-in-RTL isolation technique |

## License

[MIT](LICENSE) — see [CREDITS.md](CREDITS.md) for full copyright notices.
