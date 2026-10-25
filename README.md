# Expert PDF Reader

**English** · [简体中文](docs/README.zh-CN.md) · [繁體中文](docs/README.zh-TW.md) · [日本語](docs/README.ja.md) · [한국어](docs/README.ko.md)

A native macOS PDF reader built for reading: tabs, Split View, and Day / Sepia / Night page themes rendered on the GPU. The interface is inspired by PDF Expert 3, without editing, annotation or subscriptions.

---

## ✨ Features

- **Reading Themes**
  - **Day**: original colors on a `#DCDCDE` / `#131314` canvas.
  - **Sepia**: warm `#F5EFDC` paper, `#3F2A18` ink, `#E5DECF` canvas.
  - **Night**: soft inversion ($`v = 0.75 - 0.25(R+G+B)`$): `#000000` paper and `#BFBFBF` ink to avoid glare in the dark, `#202223` canvas.
  - **Follow System** switches between Day and Night with the system appearance, optionally using Sepia instead of Day.
  - Pages stay sharp at every zoom level: the color matrix is applied above `NSClipView`'s magnification, so PDFKit's tiles render at full Retina resolution.
- **12 Languages**: **简体中文**, **繁體中文**, **English**, **日本語**, **한국어**, **Français**, **Deutsch**, **Español**, **Italiano**, **Português**, **Русский** and **Українська**, or Follow System; switchable live from Settings (`⌘,`), the View menu or the View Settings panel. The built-in Reading Guide PDF is localized too.
- **Interface**
  - **Unified 40pt title bar**: traffic lights centered on the tab strip, icon-only Home tab, document tabs (close on hover, context menu) and `+` to open files.
  - **Toolbar**: Document Summary / Page Overview / View Settings toggles, zoom pop-up with presets and `−` / `+`, theme switcher, Clear Margins, Rotate, Share, Bookmark and a search field.
  - **Left dock (240pt)**: Thumbnails / Outline (highlights the section you are reading) / Bookmarks, or the View Settings panel (page layout, split view, reading theme, clear margins, rotation, appearance, language).
  - **Right search dock**, bottom-right **page counter** (click → Go to Page) and a **Page Overview** grid (`⌃⌘1`).
  - Tab strip, toolbar and panels follow the **System / Light / Dark** appearance.
- **Home Tab**: sidebar with Home, Recents and Favorites (plus Open File…, Reading Guide and Settings), a drag-and-drop area, reading-theme cards and document grids with locale-aware dates.
- **Tabs & Split View**: vertical (left / right) or horizontal (top / bottom) Split View with Swap Sides, Sync Scroll & Zoom, and the Home tab as a picker for the second document.
- **Reading**
  - Single Page, Two Pages and Two Pages with Single Cover (`⌘1`, `⌘2`, `⌘3`).
  - **`←` / `→`** turn the page in the focused pane.
  - **Clear Margins (`⇧⌘M`)** detects the content bounds of each page and crops the margins, computed in the background.
  - **Left sidebar (`⌘B`)**: themed page thumbnails, the document outline and bookmarks (`⌘D`).
  - **Full-text search (`⌘F`)** runs in the background and lists results per page as they are found, with highlighted context.
  - **Picks up where you left off**: every document reopens at its last page, zoom and layout, and the last session's tabs are restored on launch.
  - **Password-protected PDFs** ask for their password; files that can't be opened say why.
  - Drop PDFs anywhere on the window or on the Dock icon; `⌘=` zooms in as well as `⌘+`.
- **Fast Home Tab**: Recents keep up to 50 documents, cover thumbnails load in the background and are cached on disk, and moved or renamed files stay in Recents / Favorites with their bookmarks and reading position.
- **Original App Icon**: a dog-eared page shifting diagonally through Day → Sepia → Night, drawn in code by `scripts/make_app_icon.swift`.

---

## 📦 Install

Download `Expert-PDF-Reader-<version>.dmg` from [Releases](https://github.com/InkCitrus/Expert-PDF-Reader/releases), open it and drag **Expert PDF Reader** into **Applications**. Requires macOS 14 or later (Apple Silicon or Intel).

Release builds are not notarized by Apple yet, so macOS blocks the first launch. Open **System Settings › Privacy & Security** and click **Open Anyway**, or run:

```zsh
xattr -dr com.apple.quarantine "/Applications/Expert PDF Reader.app"
```

---

## 🛠 Build & Run

Requires the Xcode Command Line Tools (`xcode-select --install`).

```zsh
./build.sh && open "build/Expert PDF Reader.app"
```

By default `build.sh` builds against the macOS SDK that `xcrun` selects. SwiftUI in the macOS 27 SDK needs a compiler plugin (SwiftUIMacros) that comes with Xcode but not with the Command Line Tools, so without Xcode `build.sh` falls back to the newest installed SDK that works and prints which one it used. To choose the SDK yourself, set `SDK_PATH`:

```zsh
SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./build.sh
```

Build a universal (Apple Silicon + Intel) app and package it as a `.dmg`:

```zsh
ARCHS="arm64 x86_64" ./build.sh && ./scripts/make_dmg.sh
```

To publish a release, either push a `v*` tag (`git tag v0.1.0 && git push origin v0.1.0`), publish a release with a new `v*` tag on GitHub, or run the **Release** workflow from the Actions tab with a version number. `.github/workflows/release.yml` then builds the `.dmg` and attaches it to the GitHub Release. CI also builds a `.dmg` for every pull request and every push to `main`, and keeps it as an artifact.

Regenerate the app icon (`Assets/AppIcon.icns` + `Assets/AppIcon.png`) after editing its design:

```zsh
swift scripts/make_app_icon.swift
```

---

## ⚖️ License

[MIT](LICENSE) © 2026 InkCitrus

Expert PDF Reader is an independent project and is not affiliated with, endorsed by, or sponsored by Readdle. PDF Expert is a trademark of Readdle Inc.
