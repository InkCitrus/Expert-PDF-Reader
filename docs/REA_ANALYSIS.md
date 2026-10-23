# PDF Expert (v3.13.4) Reverse Engineering & Clean-Room Reader Implementation

> Workflow based on [`morluto/rea`](https://github.com/morluto/rea): **`Decompile → Understand → Recreate`**
> Target Binary: `/Applications/PDF Expert.app` (`v3.13.4`, Build `1132`, `com.readdle.PDFExpert-Mac`)
> Scope: **Reader-Only Edition** (Day / Sepia / Night GPU page themes + System / Light / Dark UI appearance + HomeTab + Multi-Tab + Split View + Clear Margins + Thumbnails / Outline / Bookmarks + Full-Text Search)

---

## 1. Decompile: Binary & Framework Inventory

Inspecting `/Applications/PDF Expert.app/Contents/` revealed a modular architecture split across specialized frameworks:

| Binary / Resource | Path in `/Applications/PDF Expert.app` | Role in Reading & Theme Architecture |
|---|---|---|
| `PDFExpert` | `Contents/MacOS/PDFExpert` | Main AppKit/SwiftUI host (`MainWindowController`, `TabsViewController`, `PDFDocumentsSplitViewController`, `PDFDocumentPresentationViewController`, `DocumentDisplaySettingsPanelViewController`) |
| `RDPDFKit.framework` | `Contents/Frameworks/RDPDFKit.framework` | PDF rendering view layer (`RDPDFDocumentView`, `RDPDFPageView`, `RDPDFScrollView`, `PDFViewTheme` state machine) |
| `RDPDFShaders.metallib` | `RDPDFKit.framework/Resources/RDPDFShaders.metallib` | Precompiled Apple Metal GPU shader library for Day / Sepia / Night page rendering |
| `RDPDFKitCore.framework` | `Contents/Frameworks/RDPDFKitCore.framework` | C++17 / ObjC++ core engine (`AGENTS.md` embedded inside `Resources/AGENTS.md`) |
| `HomeTab.framework` | `Contents/Frameworks/HomeTab.framework` | SwiftUI Home Tab (`ARCHITECTURE.md` embedded inside `Resources/ARCHITECTURE.md`) |
| `RDDesignLibrary.framework` | `Contents/Frameworks/RDDesignLibrary.framework` | Unified design token palette (`RDDesignLibrary.ColorPalette` & `Assets.car`) |

---

## 2. Understand: Exact Disassembly & Shader Extraction

### 2.1 GPU Page Theme Shaders (`RDPDFShaders.metallib`)

Strings and symbol inspection of `RDPDFShaders.metallib` exposed 8 shader entry points:
- `texturingModeVertexShader`
- `normalTexturingModeFragmentShader` (Day / 日间)
- `sepiaTexturingModeFragmentShader` (Sepia / 纸质)
- `nightTexturingModeFragmentShader` (Night / 夜间)
- `TiledLayer_Vertex`, `TiledLayer_Normal_Fragment`, `TiledLayer_Sepia_Fragment`, `TiledLayer_Night_Fragment`

By executing `RDPDFShaders.metallib` on an offscreen `MTLTexture` probe (`test_shader.swift`) across basis colors `(0,0,0)`, `(1,0,0)`, `(0,1,0)`, `(0,0,1)`, and `(1,1,1)`, we recovered the exact affine color transformation matrices:

#### Sepia Mode (`sepiaTexturingModeFragmentShader` / `TiledLayer_Sepia_Fragment`)
$$\begin{bmatrix} R' \\ G' \\ B' \\ A' \end{bmatrix} = \begin{bmatrix} 0.207 & 0.407 & 0.100 & 0 \\ 0.224 & 0.441 & 0.108 & 0 \\ 0.222 & 0.438 & 0.109 & 0 \\ 0 & 0 & 0 & 1 \end{bmatrix} \begin{bmatrix} R \\ G \\ B \\ A \end{bmatrix} + \begin{bmatrix} 0.247 \\ 0.165 \\ 0.094 \\ 0 \end{bmatrix}$$

- **White Paper `(1, 1, 1)`** $\rightarrow$ `(0.961, 0.938, 0.863)` = **`#F5EFDC`** (warm cream paper)
- **Black Ink `(0, 0, 0)`** $\rightarrow$ `(0.247, 0.165, 0.094)` = **`#3F2A18`** (deep espresso brown ink, never harsh black)

#### Night Mode (`nightTexturingModeFragmentShader` / `TiledLayer_Night_Fragment`)
$$v = 0.75 - \text{dot}\left(\text{rgb}, (0.25, 0.25, 0.25)\right) = 0.75 - 0.25 R - 0.25 G - 0.25 B$$
$$\text{out} = \text{float4}(v, v, v, A)$$

- **White Paper `(1, 1, 1)`** $\rightarrow$ `(0.0, 0.0, 0.0)` = **`#000000`** (pure black page surface)
- **Black Ink `(0, 0, 0)`** $\rightarrow$ `(0.75, 0.75, 0.75)` = **`#BFBFBF`** (75% soft silver-gray text to eliminate halation/glare in dark environments)

---

### 2.2 Canvas Background Colors (`-[RDPDFDocumentView documentBackgroundColorForViewTheme:]`)

Disassembling `RDPDFKit.framework` at `0xab1b4` revealed how `RDPDFDocumentView` selects the scroll-canvas backdrop behind pages:

```objc
// -[RDPDFDocumentView documentBackgroundColorForViewTheme:] @ 0xab1b4
switch (viewTheme) {
    case 0: // Day (日间)
        return [RDDesignLibrary.ColorPalette systemBackgroundColor]; // #DCDCDE (Light) / #131314 (Dark)
    case 1: // Night (夜间)
        return [NSColor colorWithSRGBRed:0.125490 green:0.133333 blue:0.137255 alpha:1.0]; // #202223
    case 2: // Sepia (纸质)
        return [NSColor colorWithCalibratedRed:0.90 green:0.87 blue:0.81 alpha:1.0]; // #E5DECF
}
```

---

### 2.3 Design Tokens (`RDDesignLibrary.ColorPalette`)

Disassembling `RDDesignLibrary.framework` (`0x1b6d0 - 0x1cb20`) and dumping `Assets.car` yielded the exact light/dark color tokens:

| Token | Light Appearance (`aqua`) | Dark Appearance (`darkAqua`) |
|---|---|---|
| `systemBackgroundColor` | `#DCDCDE` `(220, 220, 222)` | `#131314` `(19, 19, 20)` |
| `secondarySystemBackgroundColor` | `#EEEEF0` `(238, 238, 240)` | `#2A2A2E` `(42, 42, 46)` |
| `tertiarySystemBackgroundColor` | `#F4F4F7` `(244, 244, 247)` | `#343438` `(52, 52, 56)` |
| `quaternarySystemBackgroundColor` | `#FCFCFF` `(252, 252, 255)` | `#3D3D42` `(61, 61, 66)` |
| `primaryTintColor` | `#2FA5FF` `(47, 165, 255)` | `#2FA5FF` `(47, 165, 255)` |
| `brightPrimaryTintColor` | `#7BC6FF` `(123, 198, 255)` | `#7BC6FF` `(123, 198, 255)` |
| `systemDarkBlueColor` | `#0D72FF` `(13, 114, 255)` | `#0D72FF` `(13, 114, 255)` |
| `PE/Label/Primary` | `#17171A` `(23, 23, 26)` | `#E3E3E5` `(227, 227, 229)` |
| `PE/Label/Secondary` | `#46464D` `(70, 70, 77)` | `#B1B1B2` `(177, 177, 178)` |
| `PE/Label/Tertiary` | `#7A7A80` `(122, 122, 128)` | `#87878C` `(135, 135, 140)` |
| `PE/Label/Quaternary` | `#969699` `(150, 150, 153)` | `#757580` `(117, 117, 128)` |

---

### 2.4 HomeTab Architecture (`HomeTab.framework/Resources/ARCHITECTURE.md`)

`HomeTab.framework` inadvertently shipped its internal `ARCHITECTURE.md`, detailing:
- **Layout Metrics**: `HomeTabSidebarView` fixed at `216pt` width with `.thinMaterial`, minimum window width `600pt`, horizontal card carousels (`HomeDocumentsHorizontalSection`), `DocumentCardView` (`160pt × 220pt`) with favorite star button on hover and context menu (`Open`, `Add/Remove Favorite`, `Show in Finder`, `Remove from Recents`).
- **Symlink Normalization**: `URL.symlinkNormalizedURL` (`standardizedFileURL.resolvingSymlinksInPath()`) inside `DocumentID` so `/var/...` and `/private/var/...` resolve to the same identity.
- **Locale-Aware Date Formatting**: `DocumentsStore` listens to `NSLocale.currentLocaleDidChangeNotification` (`PEM-10270`) and refreshes `DocumentItem.dateOpenedText`.
- **Split-Screen Reuse**: `HomeTabViewFactory.makeSplitScreenHomeTabView(in:)` embeds the HomeTab inside the secondary pane of `PDFDocumentsSplitViewController` to pick a comparison document.

---

### 2.5 High-DPI `PDFScrollView` Filtering on macOS (Preserving Retina + Zoom Sharpness)

Inspection of macOS `PDFKit`'s layer tree showed that `PDFScrollView`'s `NSClipView.layer` carries `transform = CATransform3DMakeScale(magnification, magnification, 1.0)`. Inside `NSClipView.layer`, `PDFPageLayer` and its `tilesContainer` (`sublayers[2].sublayers[0]`) have `contentsScale = 1.0`, while leaf `PDFPageLayerTile` layers render at `contentsScale = backingScaleFactor * magnification`.

Attaching `CIFilter` to any sublayer *inside* `NSClipView.layer` forces CoreAnimation (`CARenderServer`) to rasterize that subtree into an offscreen texture in `NSClipView`'s un-magnified coordinate space before applying `NSClipView.layer.transform`, causing bilinear blur when zoomed or when switching modes.

In `ThemedPDFView` (`PDFReaderCanvasView.swift`), we attach the `CIColorMatrix` filter to `PDFScrollView.layer` (**above** `NSClipView.layer`'s scale transform, where `transform = identity` and `contentsScale = backingScaleFactor`), keep `scrollView.drawsBackground = false`, and paint `documentBackgroundNSColor` on the root `ThemedPDFView.layer`. This preserves 100% of native `PDFPageLayerTile` Retina + zoom sharpness while keeping exact `#E5DECF` (Sepia) and `#202223` (Night) canvas background colors.

---

## 3. Recreate: Clean-Room Project Structure

```text
Expert-PDF-Reader/
├── Package.swift
├── build.sh
├── Expert PDF Reader.app/                 # Built macOS application bundle
├── Assets/
│   └── AppIcon.icns / AppIcon.png         # Original tri-theme app icon (generated)
├── scripts/
│   └── make_app_icon.swift                # Draws the icon with SwiftUI ImageRenderer + iconutil
├── docs/
│   └── REA_ANALYSIS.md
└── Sources/ExpertPDFReader/
    ├── Resources/
    │   ├── RDPDFShaders.metallib          # Extracted Metal shader library
    │   ├── en.lproj/Localizable.strings   # English localization strings
    │   └── zh-Hans.lproj/Localizable.strings # Simplified Chinese localization strings
    ├── Localization/
    │   └── L10n.swift                     # Reactive i18n manager (System / 简体中文 / English)
    ├── Shaders/
    │   ├── RDPDFShaders.metal             # Reconstructed Metal shader source
    │   └── MetalShaderRenderer.swift      # Metal + CoreImage GPU theme pipeline
    ├── DesignLibrary/
    │   └── RDDesignLibrary.swift          # Exact RDDesignLibrary.ColorPalette & PDFReadingThemeMode
    ├── Models/
    │   ├── AppStore.swift                 # DocumentID, DocumentsStore, DocumentTabState, AppStore
    │   └── SamplePDFGenerator.swift       # Bilingual 4-page sample PDF with TOC & wide margins
    ├── HomeTab/
    │   └── HomeTabView.swift              # HomeTabRootView, Sidebar (216pt), DropCard, DocumentCards
    ├── Reader/
    │   ├── PDFReaderCanvasView.swift      # RDPDFDocumentViewWrapper & ThemedPDFView (←/→ navigation)
    │   ├── ReaderSidebarsAndToolbars.swift# Toolbar, left dock (Thumbnails/Outline/Bookmarks, View Settings)
    │   ├── ReaderOverlays.swift           # Search results dock, page counter, Page Overview grid
    │   └── PDFReaderView.swift            # Full reader + Vertical/Horizontal Split View comparison
    └── App/
        ├── WindowChrome.swift             # Hidden title bar, traffic lights centered on the 40pt tab strip
        ├── MainWindowView.swift           # Unified tab strip (HomeTabButtonView + Document Tabs)
        ├── SettingsView.swift             # Settings scene (⌘,): language + appearance + reading theme
        └── ExpertPDFReaderApp.swift       # App entry point + localized MainMenu keyboard shortcuts
```
