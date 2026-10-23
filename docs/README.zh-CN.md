# Expert PDF Reader (`OpenPDFExpert`)

[English](../README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

**PDF Expert (v3.13.4) 阅读版**的 macOS 原生净室（clean-room）实现，遵循 [`morluto/rea`](https://github.com/morluto/rea) 的逆向工程方法（`Decompile → Understand → Recreate`，即“反编译 → 理解 → 重建”）构建。

仅保留核心的 **PDF 阅读与主题切换**体验，不含编辑、批注、付费墙等冗余功能。

---

## ✨ 功能特性

- **1:1 复刻的 GPU 页面阅读主题（`RDPDFShaders.metallib`）**
  - **日间（Day）**：清晰还原原始色彩（纸张 `#FFFFFF`，画布背景 `#DCDCDE` / `#131314`）。
  - **纸质（Sepia）**：精确还原 `sepiaTexturingModeFragmentShader` 的仿射颜色矩阵（暖奶油色纸张 `#F5EFDC`，深咖啡色墨迹 `#3F2A18`，画布背景 `#E5DECF`）。
  - **夜间（Night）**：精确还原 `nightTexturingModeFragmentShader` 的亮度反转（$v = 0.75 - 0.25(R+G+B)$；纸张 `#000000`；墨迹为 75% 亮度的柔和银灰色 `#BFBFBF`，避免在暗处阅读时刺眼；画布背景 `#202223`）。
  - **精准的 `PDFPageLayer` 子图层滤镜**：仅对图块内容层（`sublayers[2].sublayers[0]`）和纸张层（`sublayers[3]`）施加滤镜，保留自然的投影（`sublayers[0..1]`）与文本选区高亮（`sublayers[2].sublayers[1]`）。
- **PDF Expert 3 风格界面**
  - **一体化 40pt 标题栏**：窗口红绿灯按钮在标签栏中垂直居中；仅显示图标的主页标签（`HomeTabButtonView`）、文档标签（悬停时显示关闭按钮，支持右键菜单），以及用于打开文件的 `+` 按钮。
  - **工具栏**：「文档概要」「页面概览」「显示选项」开关，带预设比例和 `−`/`+` 按钮的缩放弹出菜单，日间 / 纸质 / 夜间切换器，清除空白边、旋转、分享、书签按钮，以及搜索框。
  - **左侧面板（240pt）**：通过图标分段控件切换「缩略图」「大纲」（高亮当前阅读的章节）「书签」，或显示「显示选项」面板（页面布局、分屏视图、阅读主题、清除空白边、旋转、界面外观）。
  - **右侧搜索结果面板**、右下角**页码指示器**（点击即可「前往页码」），以及**页面概览**网格（`⌃⌘1`）。
  - 不同于 PDF Expert 始终为石墨色的界面框架，本应用的标签栏、工具栏和面板会随**界面外观**（跟随系统 / 浅色 / 深色）切换配色，配色取自 `RDDesignLibrary` 中成对的浅色 / 深色设计令牌。
- **主页标签（`HomeTab.framework` 架构）**
  - 不透明的 `216pt` 侧边栏（「主页」「最近打开」「收藏夹」，以及「打开文件…」「阅读指南」「设置」）、虚线拖放区、阅读主题卡片、「最近打开」/「收藏夹」网格（「清除全部 · 查看全部」）、经符号链接规范化的 `DocumentID`，以及按系统区域格式显示的时间戳。
- **多标签页与分屏对比（`PDFDocumentsSplitViewController`）**
  - 垂直分屏（左右）与水平分屏（上下）、对调位置、同步滚动和缩放，并内嵌 HomeTab 选择器，用于挑选第二份对比文档。
- **阅读功能**
  - 页面布局：「单页」`⌘1`、「双页」`⌘2`、「双页（首屏单页显示）」`⌘3`。
  - **清除空白边（`⇧⌘M`）**：智能检测页面墨迹的边界框，自动裁切页边距。
  - **左侧面板（`⌘B`）**：页面缩略图（按当前 GPU 主题实时渲染）、多级目录（`PDFOutline`）以及书签（`⌘D`）。
  - **全文搜索（`⌘F`）**：即时高亮关键词；结果按页列出，并附带高亮的上下文摘要。
- **原创应用图标**：一张折角的页面，沿对角线依次呈现日间 → 纸质 → 夜间，由 `scripts/make_app_icon.swift` 用代码绘制。

---

## 🛠 构建与运行

在仓库根目录下执行：

```zsh
./build.sh && open OpenPDFExpert.app
```

修改图标设计后，重新生成应用图标（`Assets/AppIcon.icns` + `Assets/AppIcon.png`）：

```zsh
swift scripts/make_app_icon.swift
```

---

## 📄 逆向工程文档

有关 `/Applications/PDF Expert.app` 的完整反汇编、着色器矩阵与架构分析，请参阅 [docs/REA_ANALYSIS.md](REA_ANALYSIS.md)（英文）。
