# AhaKey Studio — Luis's Build (English UI + Cantonese Voice)

Custom build of [AhakeyAI/desktop](https://github.com/AhakeyAI/desktop) with two changes:

1. **English UI** — all user-visible strings translated from Chinese.
2. **Configurable speech locale** — the voice key can transcribe Cantonese (or any Apple Speech locale) regardless of the macOS system language, via a `speechLocales` setting.

Fork / source: `github.com/luisarn/desktop`, branch `luis/cantonese-en`.

## Contents

- `AhaKey-Studio-macOS-prod-*.dmg` — universal installer (Apple Silicon + Intel)

## Install

1. Open the DMG and drag **AhaKey Studio** to **Applications**.
2. First launch: right-click the app → **Open** → **Open**.
   (Gatekeeper warns because the app is signed with a personal Apple Development
   certificate, not notarized. This is expected.)
3. The in-app **Onboarding** walks you through the required permissions:
   Bluetooth, Microphone, Speech Recognition, Input Monitoring, Accessibility.
   All five are needed for the physical mic key to work and for text to be
   pasted into your editor.

## Enable Cantonese dictation

Only needed if the Mac's system language is **not** Cantonese/Chinese
(the app follows the system language by default). Run once in Terminal:

```bash
defaults write lab.jawa.ahakeyconfig speechLocales "yue-HK,zh-HK"
```

- Locales are tried in order; unavailable ones are skipped.
- `yue-HK` is not available on all macOS versions — `zh-HK` (Cantonese) is the reliable one.
- To revert to system-language behavior:

```bash
defaults delete lab.jawa.ahakeyconfig speechLocales
```

## Notes

- **Do not auto-update** from the vendor — an official update overwrites this
  build. To update, merge upstream changes in the fork and rebuild.
- Rebuild from source:

  ```bash
  git clone https://github.com/luisarn/desktop.git
  cd desktop/ahakeyconfig-mac
  zsh scripts/package_dmg.sh   # produces dist/*.dmg
  ```

- Diagnostics logs (useful when something doesn't work):
  `~/Library/Application Support/AhaKeyConfig/diagnostics/`
  — `native-speech.log` shows which speech locale was used
  (`using configured speech locale=zh-HK`).

Built 2026-08-27 from commit `6afa1b3`.
