# Expert PDF Reader (`OpenPDFExpert`)

**English** · [简体中文](docs/README.zh-CN.md) · [繁體中文](docs/README.zh-TW.md) · [日本語](docs/README.ja.md) · [한국어](docs/README.ko.md)

Clean-room macOS native implementation of **PDF Expert (v3.13.4) Reader Edition**, built following the [`morluto/rea`](https://github.com/morluto/rea) (`Decompile → Understand → Recreate`) reverse-engineering methodology.

Retains only the core **PDF reading & theme switching** experience (no editing, annotation, or paywall bloat).

---

## ✨ Features

- **1:1 GPU Page Reading Themes (`RDPDFShaders.metallib`)**
  - **Day (日间)**: Crisp original colors (`#FFFFFF` paper, `#DCDCDE` / `#131314` canvas backdrop).
  - **Sepia (纸质)**: Exact affine color matrix from `sepiaTexturingModeFragmentShader` (`#F5EFDC` warm cream paper, `#3F2A18` espresso ink, `#E5DECF` canvas backdrop).
  - **Night (夜间)**: Exact luminance inversion from `nightTexturingModeFragmentShader` ($v = 0.75 - 0.25(R+G+B)$, `#000000` paper, `#BFBFBF` 75% soft silver ink to prevent dark-room glare, `#202223` canvas backdrop).
  - **Surgical `PDFPageLayer` Sublayer Filtering**: Filters only the tile content layer (`sublayers[2].sublayers[0]`) and paper layer (`sublayers[3]`), preserving natural drop shadows (`sublayers[0..1]`) and text selection highlights (`sublayers[2].sublayers[1]`).
- **PDF Expert 3–Style Interface**
  - **Unified 40pt title bar**: traffic lights centered on the tab strip, icon-only Home tab (`HomeTabButtonView`), document tabs (close on hover, context menu) and `+` to open files.
  - **Toolbar**: Document Summary / Page Overview / View Settings toggles, zoom pop-up with presets and `−`/`+`, Day / Sepia / Night switcher, Clear Margins, Rotate, Share, Bookmark and a search field.
  - **Left dock (240pt)**: icon segmented Thumbnails / Outline (highlights the section you are reading) / Bookmarks, or the View Settings panel (page layout, split view, reading theme, clear margins, rotation, appearance).
  - **Right search dock**, bottom-right **page counter** (click → Go to Page) and a **Page Overview** grid (`⌃⌘1`).
  - Unlike PDF Expert's always-graphite chrome, the tab strip, toolbar and panels follow the **System (跟随系统) / Light (浅色) / Dark (深色)** appearance (`RDDesignLibrary` light/dark token pairs).
- **Home Tab (`HomeTab.framework` Architecture)**
  - Opaque `216pt` sidebar (`主页`, `最近打开`, `收藏夹`, plus `打开文件…`, `阅读指南`, `设置`), dashed drag-and-drop area, reading-theme cards, Recents / Favorites grids (`清除全部 · 查看全部`), symlink-normalized `DocumentID`, and locale-aware timestamps.
- **Multi-Tab & Split-Screen Comparison (`PDFDocumentsSplitViewController`)**
  - Vertical (left/right) and Horizontal (top/bottom) Split View, Swap Sides, Sync Scroll & Zoom, and embedded HomeTab picker for secondary comparison documents.
- **Reading Suite**
  - Single Page, Two Pages, Two Pages with Single Cover (`⌘1`, `⌘2`, `⌘3`).
  - **Clear Margins (智能清除空白边, `⇧⌘M`)**: Automatically detects ink bounding boxes and crops page margins.
  - **Left Sidebar (`⌘B`)**: Page Thumbnails (rendered with active GPU theme), hierarchical Table of Contents (`PDFOutline`), and Bookmarks (`⌘D`).
  - **Full-Text Search (`⌘F`)**: Instant keyword highlighting; results listed per page with highlighted context snippets.
- **Original App Icon**: a dog-eared page shifting diagonally through Day → Sepia → Night, drawn in code by `scripts/make_app_icon.swift`.

---

## 🛠 Build & Run

```zsh
./build.sh && open OpenPDFExpert.app
```

Regenerate the app icon (`Assets/AppIcon.icns` + `Assets/AppIcon.png`) after editing its design:

```zsh
swift scripts/make_app_icon.swift
```

---

## 📄 Reverse Engineering Documentation

See [docs/REA_ANALYSIS.md](docs/REA_ANALYSIS.md) for the complete disassembly, shader matrices, and architecture analysis of `/Applications/PDF Expert.app`.
