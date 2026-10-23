# Expert PDF Reader (`OpenPDFExpert`)

[English](../README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

以無塵室（clean-room）方式實作的 macOS 原生 **PDF Expert (v3.13.4) 閱讀版**，依循 [`morluto/rea`](https://github.com/morluto/rea) 的逆向工程方法（`Decompile → Understand → Recreate`，即「反編譯 → 理解 → 重建」）打造。

只保留核心的 **PDF 閱讀與主題切換**體驗，不含編輯、註解、付費牆等多餘功能。

---

## ✨ 功能特色

- **1:1 重現的 GPU 頁面閱讀主題（`RDPDFShaders.metallib`）**
  - **日間（Day）**：清晰呈現原始色彩（紙張 `#FFFFFF`，畫布背景 `#DCDCDE` / `#131314`）。
  - **紙質（Sepia）**：精確重現 `sepiaTexturingModeFragmentShader` 的仿射色彩矩陣（溫暖的奶油色紙張 `#F5EFDC`，深咖啡色墨跡 `#3F2A18`，畫布背景 `#E5DECF`）。
  - **夜間（Night）**：精確重現 `nightTexturingModeFragmentShader` 的亮度反轉（$v = 0.75 - 0.25(R+G+B)$；紙張 `#000000`；墨跡為 75% 亮度的柔和銀灰色 `#BFBFBF`，避免在暗處閱讀時刺眼；畫布背景 `#202223`）。
  - **精準的 `PDFPageLayer` 子圖層濾鏡**：僅對圖塊內容層（`sublayers[2].sublayers[0]`）與紙張層（`sublayers[3]`）套用濾鏡，保留自然的陰影（`sublayers[0..1]`）與文字選取反白（`sublayers[2].sublayers[1]`）。
- **PDF Expert 3 風格介面**
  - **一體化 40pt 標題列**：視窗紅綠燈按鈕在標籤列中垂直置中；僅顯示圖示的主頁標籤（`HomeTabButtonView`）、文件標籤（游標停留時顯示關閉按鈕，支援右鍵選單），以及用來開啟檔案的 `+` 按鈕。
  - **工具列**：「文檔概要」「頁面概覽」「顯示選項」切換按鈕，附預設比例與 `−`/`+` 按鈕的縮放彈出式選單，日間 / 紙質 / 夜間切換器，清除空白邊、旋轉、分享、書籤按鈕，以及搜尋欄位。
  - **左側面板（240pt）**：以圖示分段控制項切換「縮略圖」「大綱」（標示目前閱讀的章節）「書籤」，或顯示「顯示選項」面板（頁面佈局、分屏視圖、閱讀主題、清除空白邊、旋轉、界面外觀）。
  - **右側搜尋結果面板**、右下角**頁碼指示器**（點一下即可「前往頁碼」），以及**頁面概覽**網格（`⌃⌘1`）。
  - 有別於 PDF Expert 始終維持石墨色的視窗外框，本 App 的標籤列、工具列與面板會依**界面外觀**（跟隨系統 / 淺色 / 深色）切換配色，色彩取自 `RDDesignLibrary` 中成對的淺色 / 深色設計 token。
- **主頁標籤（`HomeTab.framework` 架構）**
  - 不透明的 `216pt` 側邊欄（「主頁」「最近打開」「收藏夾」，以及「打開文件…」「閱讀指南」「設置」）、虛線拖放區、閱讀主題卡片、「最近打開」/「收藏夾」網格（「清除全部 · 查看全部」）、經符號連結正規化的 `DocumentID`，以及依系統地區格式顯示的時間戳記。
- **多標籤與分屏對照（`PDFDocumentsSplitViewController`）**
  - 垂直分屏（左右）與水平分屏（上下）、對調位置、同步滾動和縮放，並內嵌 HomeTab 選擇器，用來挑選第二份對照文件。
- **閱讀功能**
  - 頁面佈局：「單頁」`⌘1`、「雙頁」`⌘2`、「雙頁（首屏單頁顯示）」`⌘3`。
  - **清除空白邊（`⇧⌘M`）**：自動偵測頁面墨跡的邊界框，裁切頁邊距。
  - **左側面板（`⌘B`）**：頁面縮圖（依目前的 GPU 主題即時渲染）、多層級目錄（`PDFOutline`）與書籤（`⌘D`）。
  - **全文搜尋（`⌘F`）**：即時標示關鍵字；結果依頁列出，並附上標示關鍵字的上下文摘要。
- **原創 App 圖示**：一張折角的頁面，沿對角線依序呈現日間 → 紙質 → 夜間，由 `scripts/make_app_icon.swift` 以程式碼繪製。

---

## 🛠 建置與執行

在儲存庫根目錄下執行：

```zsh
./build.sh && open OpenPDFExpert.app
```

修改圖示設計後，重新產生 App 圖示（`Assets/AppIcon.icns` + `Assets/AppIcon.png`）：

```zsh
swift scripts/make_app_icon.swift
```

---

## 📄 逆向工程文件

關於 `/Applications/PDF Expert.app` 的完整反組譯、著色器矩陣與架構分析，請參閱 [docs/REA_ANALYSIS.md](REA_ANALYSIS.md)（英文）。
