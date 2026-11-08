# Expert PDF Reader

**English** · [简体中文](docs/README.zh-CN.md) · [繁體中文](docs/README.zh-TW.md) · [日本語](docs/README.ja.md) · [한국어](docs/README.ko.md)

A native macOS PDF reader built for reading: tabs, Split View, and Day / Sepia / Night page themes rendered on the GPU. The interface is inspired by PDF Expert 3, without editing, annotation or subscriptions.

---

## ✨ Features

- **Reading Themes**
  - **Day**: original colors on a `#DCDCDE` / `#131314` canvas.
  - **Sepia**: warm `#F5EFDC` paper, `#3F2A18` ink, `#E5DECF` canvas; colors keep their hue, so figures and highlights stay distinguishable.
  - **Night**: soft inversion of lightness ($`L' = 0.75(1 - L)`$) that keeps hues: `#000000` paper and `#BFBFBF` ink to avoid glare in the dark, colored figures stay recognizable, `#202223` canvas.
  - **Follow System** switches between Day and Night with the system appearance, optionally using Sepia instead of Day. Configure the light-mode Sepia option in **View › Reading Theme**; it is available when Follow System is selected.
  - Pages stay sharp at every zoom level: the color matrix is applied above `NSClipView`'s magnification, so PDFKit's tiles render at full Retina resolution.
- **12 Languages**: **简体中文**, **繁體中文**, **English**, **日本語**, **한국어**, **Français**, **Deutsch**, **Español**, **Italiano**, **Português**, **Русский** and **Українська**, or Follow System; switchable live from Settings (`⌘,`) or the View menu. The built-in Reading Guide PDF is localized too.
- **Interface**
  - **Title bar**: Sidebar and Home stay beside the native window controls in either tab layout. **Open File…** follows the tab list.
  - **Toolbar**: zoom, a Layout menu for page layout, Page Overview and split view, reading theme, Clear Margins, rotation, Share, Bookmark, and search.
  - **Left sidebar**: Thumbnails, Outline, and Bookmarks stay in their own page-navigation sidebar. The independent tab rail expands to a wider floating document list over the reading area. The list collapses when the pointer leaves; `⌘B` toggles page navigation.
  - **Right search dock**, bottom-right **page counter** (click or `⌥⌘G` → Go to Page) and a **Page Overview** grid (`⌃⌘1`).
  - Tab strip, toolbar and panels follow the **System / Light / Dark** appearance.
- **Home Tab**: sidebar with Home, Recents and Favorites (plus Open File…, Shortcuts & Tips, Reading Guide and Settings; Help › Reading Guide, `⌘?`, opens the guide from anywhere), a drag-and-drop area, reading-theme cards, and document grids with locale-aware dates.
- **Shortcuts & Tips Guide (`⌘/`)**: a dedicated, searchable keyboard cheat sheet with tactile keycap badges and category filters (*Tabs*, *Navigation*, *View & Zoom*, *Search & Bookmarks*, *Tips*). Open anytime with `⌘/`, the `?` button on the tab bar, or Help › Shortcuts & Tips.
- **Tabs & Windows**:
  - **Browser-style multi-window**: drag a tab out of the tab bar to detach it into a new window, drag tabs between windows to merge, or choose Window › Merge All Windows.
  - **Dock & New Window (`⌘N`)**: right-click the Dock icon for New Window, Open… and recent files.
  - **Tab management**: drag tabs to reorder, show the full file path in a standard tooltip, and open the All Tabs menu (`⌄`) when multiple documents are open. Duplicate filenames across folders are automatically disambiguated with parent folder names. Right-click a tab to create a named group or move it into an existing one. Groups use solid color headings and can collapse or expand. The name can be left empty to show only the color; in the top tab bar, one colored line follows the active tab’s rounded outline and continues under the other tabs in its group. In the sidebar, a matching vertical line runs behind the group in a separate left gutter, including in the compact rail. While dragging, tabs slide into the proposed order and the group line follows the insertion slot; releasing saves the change, and Escape cancels it. Right-click a group to rename it or choose a color from the native menu; both are saved with restored tabs. Groups form separate sections, followed by ungrouped documents. Drag a group heading to move the whole group, or drag a document to New Group. Open File stays visible when the list overflows.
  - **Navigation shortcuts**: `⌃⇥` / `⌃⇧⇥` cycle document tabs (Home is skipped); `⇧⌘T` reopens closed tabs in their original slot and reading position.
  - **Mission Control**: window titles and represented file icons stay in sync with the active document across macOS Mission Control, App Exposé, Stage Manager and Dock.
  - **Split View**: vertical (left / right) or horizontal (top / bottom) Split View with Swap Sides, Sync Scroll & Zoom, and the Home tab as a picker for the second document.
- **Reading**
  - Single Page, Two Pages and Two Pages with Single Cover (`⌘1`, `⌘2`, `⌘3`); the pages of a spread meet at the spine. Books bound on the right are detected (from the PDF, or from where the page numbers sit on vertically set pages) and read right to left; View › Page Direction overrides it.
  - **Printed page numbers**: the page counter and Go to Page use the numbers printed on the pages — read from the pages themselves when the PDF's own page labels are missing or wrong — and show both pages of a spread. Roman-numeral front matter followed by Arabic numbering is recognized, the outline and thumbnails show the same numbers, and Go to Page also takes `(n)` for the n-th page of the file.
  - **`←` / `→`** turn the page in the focused pane.
  - **Clear Margins (`⇧⌘M`)** detects the content bounds of each page and crops the margins, computed in the background.
  - **Left sidebar (`⌘B`)**: themed page thumbnails, the document outline and bookmarks (`⌘D`).
  - **Local OCR**: bundled [RapidOCRLite](https://github.com/RapidAI/RapidOCRLite) models provide character positions for selecting scanned text, including traditional Chinese and vertical columns. Drag to select and use `⌘C`; the original PDF is not rewritten. Recognition runs on demand and copies join physical wraps while preserving paragraphs. No upload or Python runtime is needed.
  - **Full-text search (`⌘F`)** runs in the background and lists results per page as they are found, with highlighted context.
  - **Restore Tabs** in Settings is on by default and reopens the previous session’s tabs at startup. Turn it off to start on Home. Each PDF’s reading position, zoom and layout are saved independently and restored whenever you open it.
  - **Password-protected PDFs** ask for their password; files that can't be opened say why.
  - Drop PDFs anywhere on the window or on the Dock icon; `⌘=` zooms in as well as `⌘+`.
- **Fast Home Tab**: Recents keep up to 50 documents (the latest 10 also under File › Open Recent), cover thumbnails load in the background and are cached on disk, and moved or renamed files stay in Recents / Favorites with their bookmarks and reading position, while files that are deleted or moved to the Trash drop out of them automatically.
- **Original App Icon**: a dog-eared page shifting diagonally through Day → Sepia → Night, drawn in code by `scripts/make_app_icon.swift`.

---

## 📦 Install

Download `Expert-PDF-Reader-<version>.dmg` from [Releases](https://github.com/InkCitrus/Expert-PDF-Reader/releases), open it and drag **Expert PDF Reader** into **Applications**. Requires macOS 14 or later (Apple Silicon or Intel).

Choose **Expert PDF Reader → Check for Updates…** to check the latest stable release. When an update is available, **View Update** opens its release page for details and the download. Checks run only when requested, show a cancellable progress window, and report their result separately from the About window.

Release builds are not notarized by Apple yet, so macOS blocks the first launch. Open **System Settings › Privacy & Security** and click **Open Anyway**, or run:

```zsh
xattr -dr com.apple.quarantine "/Applications/Expert PDF Reader.app"
```

---

## 🛠 Build & Run

Requires the Xcode Command Line Tools (`xcode-select --install`). The first build downloads pinned OCR sources and models with SHA-256 verification (about 80 MB). CMake is used only for building; if missing, the script installs it into `build/OCRTools`. Model weights and native libraries are bundled in the app. Third-party notices are in `Contents/Resources/OCR`.

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
