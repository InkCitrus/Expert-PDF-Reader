# Expert PDF Reader

Clean-room macOS native implementation of **PDF Expert (v3.13.4) Reader Edition**, built following the [`morluto/rea`](https://github.com/morluto/rea) (`Decompile → Understand → Recreate`) reverse-engineering methodology.

Retains only the core **PDF reading & theme switching** experience (no editing, annotation, or paywall bloat).

---

## ✨ Features

- **1:1 GPU Page Reading Themes (Metal + Core Image color matrices)**
  - **Follow System (跟随系统)**: Automatically switches between Light and Dark reading themes to match the system/app appearance, with an optional **"Use Sepia in Light Mode (浅色时使用纸质替代日间)"** toggle.
  - **Day (日间)**: Crisp original colors (`#FFFFFF` paper, `#DCDCDE` / `#131314` canvas backdrop).
  - **Sepia (纸质)**: Exact affine color matrix from `sepiaTexturingModeFragmentShader` (`#F5EFDC` warm cream paper, `#3F2A18` espresso ink, `#E5DECF` canvas backdrop).
  - **Night (夜间)**: Exact luminance inversion from `nightTexturingModeFragmentShader` ($v = 0.75 - 0.25(R+G+B)$, `#000000` paper, `#BFBFBF` 75% soft silver ink to prevent dark-room glare, `#202223` canvas backdrop).
  - **Lossless Retina + Zoom Sharpness**: Attaches `CIColorMatrix` above `NSClipView`'s magnification transform (`PDFScrollView.layer`) so `PDFPageLayerTile` layers rasterize at full `backingScaleFactor × magnification` before color-matrix filtering.
- **Internationalization (i18n)**
  - Supports **Follow System (跟随系统)**, **Simplified Chinese (简体中文)**, and **English**, switchable live from Settings (`⌘,`), the View menu, or the View Settings panel.
- **PDF Expert 3–Style Interface**
  - **Unified 40pt title bar**: traffic lights centered on the tab strip, icon-only Home tab (`HomeTabButtonView`), document tabs (close on hover, context menu) and `+` to open files.
  - **Toolbar**: Document Summary / Page Overview / View Settings toggles, zoom pop-up with presets and `−`/`+`, Follow System / Day / Sepia / Night switcher, Clear Margins, Rotate, Share, Bookmark and a search field.
  - **Left dock (240pt)**: icon segmented Thumbnails / Outline (highlights the section you are reading) / Bookmarks, or the View Settings panel (page layout, split view, reading theme, clear margins, rotation, appearance, language).
  - **Right search dock**, bottom-right **page counter** (click → Go to Page) and a **Page Overview** grid (`⌃⌘1`).
  - Unlike PDF Expert's always-graphite chrome, the tab strip, toolbar and panels follow the **System (跟随系统) / Light (浅色) / Dark (深色)** appearance (`RDDesignLibrary` light/dark token pairs).
- **Home Tab (`HomeTab.framework` Architecture)**
  - Opaque `216pt` sidebar (`主页` / `Home`, `最近打开` / `Recents`, `收藏夹` / `Favorites`, plus `打开文件…`, `阅读指南`, `设置`), dashed drag-and-drop area, reading-theme cards, Recents / Favorites grids, symlink-normalized `DocumentID`, and locale-aware timestamps.
- **Multi-Tab & Split-Screen Comparison (`PDFDocumentsSplitViewController`)**
  - Vertical (left/right) and Horizontal (top/bottom) Split View, Swap Sides, Sync Scroll & Zoom, and embedded HomeTab picker for secondary comparison documents.
- **Reading Suite**
  - Single Page, Two Pages, Two Pages with Single Cover (`⌘1`, `⌘2`, `⌘3`).
  - **Left / Right Arrow Key Page Navigation (`←` / `→`)**: Quickly step to the previous or next page from anywhere in the reader.
  - **Clear Margins (智能清除空白边, `⇧⌘M`)**: Automatically detects ink bounding boxes and crops page margins.
  - **Left Sidebar (`⌘B`)**: Page Thumbnails (rendered with active GPU theme), hierarchical Table of Contents (`PDFOutline`), and Bookmarks (`⌘D`).
  - **Full-Text Search (`⌘F`)**: Instant keyword highlighting; results listed per page with highlighted context snippets.
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

Build a universal (Apple Silicon + Intel) app and package it as a `.dmg`:

```zsh
ARCHS="arm64 x86_64" ./build.sh && ./scripts/make_dmg.sh
```

Pushing a `v*` tag (e.g. `git tag v0.1.0 && git push origin v0.1.0`) runs `.github/workflows/release.yml`, which builds the `.dmg` and attaches it to a GitHub Release. Every push also builds a `.dmg` as a CI artifact.

Regenerate the app icon (`Assets/AppIcon.icns` + `Assets/AppIcon.png`) after editing its design:

```zsh
swift scripts/make_app_icon.swift
```

---

## 📄 Reverse Engineering Documentation

See [docs/REA_ANALYSIS.md](docs/REA_ANALYSIS.md) for the complete disassembly, shader matrices, and architecture analysis of `/Applications/PDF Expert.app`.

---

## ⚖️ License

[MIT](LICENSE) © 2026 InkCitrus

Expert PDF Reader is an independent project and is not affiliated with, endorsed by, or sponsored by Readdle. PDF Expert is a trademark of Readdle Inc.
