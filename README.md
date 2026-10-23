# Expert PDF Reader (`OpenPDFExpert`)

Clean-room macOS native implementation of **PDF Expert (v3.13.4) Reader Edition**, built following the [`morluto/rea`](https://github.com/morluto/rea) (`Decompile → Understand → Recreate`) reverse-engineering methodology.

Retains only the core **PDF reading & theme switching** experience (no editing, annotation, or paywall bloat).

---

## ✨ Features

- **1:1 GPU Page Reading Themes (`RDPDFShaders.metallib`)**
  - **Day (日间)**: Crisp original colors (`#FFFFFF` paper, `#DCDCDE` / `#131314` canvas backdrop).
  - **Sepia (纸质)**: Exact affine color matrix from `sepiaTexturingModeFragmentShader` (`#F5EFDC` warm cream paper, `#3F2A18` espresso ink, `#E5DECF` canvas backdrop).
  - **Night (夜间)**: Exact luminance inversion from `nightTexturingModeFragmentShader` ($v = 0.75 - 0.25(R+G+B)$, `#000000` paper, `#BFBFBF` 75% soft silver ink to prevent dark-room glare, `#202223` canvas backdrop).
  - **Surgical `PDFPageLayer` Sublayer Filtering**: Filters only the tile content layer (`sublayers[2].sublayers[0]`) and paper layer (`sublayers[3]`), preserving natural drop shadows (`sublayers[0..1]`) and text selection highlights (`sublayers[2].sublayers[1]`).
- **App UI Appearance (`RDDesignLibrary.ColorPalette`)**
  - Switch between **System (跟随系统)**, **Light (浅色)**, and **Dark (深色)** UI themes using exact `RDDesignLibrary` color tokens.
- **Home Tab (`HomeTab.framework` Architecture)**
  - `216pt` `.thinMaterial` sidebar (`主页`, `最近打开`, `收藏夹`), drag-and-drop import area, horizontal carousels (`已打开的文件`, `最近打开的文件`), symlink-normalized `DocumentID`, and locale-aware timestamps.
- **Multi-Tab & Split-Screen Comparison (`PDFDocumentsSplitViewController`)**
  - Multi-tab bar with pinned Home button (`HomeTabButtonView`).
  - Vertical (left/right) and Horizontal (top/bottom) Split View, Swap Sides, Sync Scroll & Zoom, and embedded HomeTab picker for secondary comparison documents.
- **Reading Suite**
  - Single Page, Two Pages, Two Pages with Single Cover (`⌘1`, `⌘2`, `⌘3`).
  - **Clear Margins (智能清除空白边, `⇧⌘M`)**: Automatically detects ink bounding boxes and crops page margins.
  - **Left Sidebar (`⌘B`)**: Page Thumbnails (rendered with active GPU theme), hierarchical Table of Contents (`PDFOutline`), and Bookmarks (`⌘D`).
  - **Full-Text Search (`⌘F`)**: Instant keyword highlighting with context snippets.

---

## 🛠 Build & Run

```zsh
./build.sh && open OpenPDFExpert.app
```

---

## 📄 Reverse Engineering Documentation

See [docs/REA_ANALYSIS.md](docs/REA_ANALYSIS.md) for the complete disassembly, shader matrices, and architecture analysis of `/Applications/PDF Expert.app`.
