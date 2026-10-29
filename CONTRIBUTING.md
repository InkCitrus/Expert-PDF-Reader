# Contributing

Thanks for your interest in Expert PDF Reader! Bug reports, fixes, translations and documentation improvements are all welcome, and so are questions in an issue. This is a spare-time project, so replies can take a few days.

## Before you start

- **It's a reader.** Expert PDF Reader is for reading PDFs: themes, tabs, Split View, navigation and search. Editing, annotation, form filling, signing and subscriptions are out of scope, so pull requests that add them won't be merged.
- **Open an issue before larger changes**, such as a new feature or a change to existing behavior, so we can agree on the approach before you write the code. Fixes, translation corrections and documentation changes can go straight to a pull request.
- **Keep it clean-room.** The interface is inspired by PDF Expert 3, but nothing may be copied or extracted from it or from any other proprietary app: no code, shaders, icons, images or text. Recreate what you see with your own code and assets.
- **Security problems** are reported privately, as described in [SECURITY.md](SECURITY.md), not in public issues.

## Reporting a bug

[Open an issue](https://github.com/InkCitrus/Expert-PDF-Reader/issues/new) and include:

- the app version (**Expert PDF Reader › About Expert PDF Reader**), your macOS version, and whether your Mac has Apple silicon or an Intel processor;
- what you did, what you expected, and what happened instead;
- the reading theme, page layout and app language, if they might matter;
- for a problem with one particular PDF, the file or a link to it, if it can be shared publicly;
- a screenshot or screen recording for anything visual.

## Building

You need the Xcode Command Line Tools (`xcode-select --install`); Xcode itself is optional.

```zsh
./build.sh && open "build/Expert PDF Reader.app"
```

`build.sh` compiles `Sources/` with `swiftc` into an ad-hoc signed app for your Mac's architecture; the comments at its top list its settings (`ARCHS`, `VERSION`, `SDK_PATH`…). Without Xcode it may build against an older macOS SDK and print a note saying so; [Build & Run](README.md#-build--run) in the README explains why.

`Package.swift` is there for Xcode and SourceKit-LSP. Run the app that `build.sh` builds: `swift run` starts a bare executable without the app bundle (`Info.plist`, icon, `.lproj` folders), which doesn't behave like the real app.

## Where things are

The app's code is in `Sources/ExpertPDFReader/`:

| Folder | Contents |
| --- | --- |
| `App/` | App delegate, menus, the main window and its tab strip, Settings |
| `HomeTab/` | The Home tab: sidebar, drop area, reading-theme cards, Recents and Favorites |
| `Reader/` | A document tab: the themed PDF canvas, toolbar, sidebars, Split View, search results, page counter and Page Overview |
| `Models/` | `AppStore` (documents, tabs, settings, bookmarks and reading positions), printed page numbers and reading direction, the Reading Guide generator |
| `Shaders/` | The Day / Sepia / Night page themes |
| `DesignLibrary/` | Reading theme and appearance types, the `AppPalette` colors |
| `Localization/` | `L10n` and its translation catalog |
| `Resources/` | `Localizable.strings` for each of the 12 languages |

`Support/Info.plist` is the app's Info.plist. `Assets/` holds the app icon, which `scripts/make_app_icon.swift` draws, and `scripts/make_dmg.sh` packages the app as a `.dmg`.

## Making changes

- Branch from `main` and keep each pull request to one topic.
- Match the code around your change: its naming, structure and comment style. Take UI colors from `AppPalette` in `DesignLibrary/DesignLibrary.swift` instead of adding new color literals.
- Check visible changes in both light and dark appearance; for changes to the reader, also in each reading theme and in Split View.
- A reading theme's colors are defined twice in `Shaders/MetalShaderRenderer.swift`: as `CIColorMatrix` filters for live pages and as Metal fragment shaders for thumbnails. Change both, and check that thumbnails still match the pages.
- If you change a keyboard shortcut, a theme color or anything else the docs describe, update README.md (and its translations, see [Documentation](#documentation)) and the Reading Guide as well.
- Run `./scripts/test_reader.sh` for session, file-lifecycle and printed-page-number regressions (it accepts `SDK_PATH` like the build). Also describe manual UI checks in the pull request; the script does not simulate mouse dragging.

## Translations

The app is translated into 12 languages, and every string the user sees needs all of them.

1. In code, write the string as `L10n.tr("简体中文", "English")`: the Simplified Chinese text first, the English second.
2. Add the other ten languages (`zh-Hant`, `ja`, `ko`, `fr`, `de`, `es`, `it`, `pt`, `ru`, `uk`) to `catalog` in `Localization/L10n.swift`, under the key `"简体中文|||English"`. A language without an entry shows the English text.
3. Add the same entries to all twelve `Resources/<language>.lproj/Localizable.strings` files, as two lines each: the `"简体中文|||English"` key and the plain `"English"` key, both set to that language's text. These files mirror the catalog, and the READMEs quote UI labels from them.

A string with a number or a name in it gets its own function in `L10n`, with a case for each language (see `pageTitle(_:)`), because word order differs between languages.

The Reading Guide PDF is generated by `Models/SamplePDFGenerator.swift`, which holds its text in all 12 languages. The app only generates the guide when it's missing, so after changing it, bump the number in `guideDirectoryName` (e.g. `Guides_v6` → `Guides_v7`) so existing installs get the new version.

If you can't cover every language, machine translation is fine as a start: say in the pull request which languages need a native speaker's review. Corrections from native speakers are always welcome.

## Documentation

README.md is translated in `docs/`: [简体中文](docs/README.zh-CN.md), [繁體中文](docs/README.zh-TW.md), [日本語](docs/README.ja.md) and [한국어](docs/README.ko.md). Make the same change in all four, or say in the pull request which ones you couldn't update.

Each README names UI items in its own language only, with the label from that language's `Localizable.strings` (`zh-Hans` for zh-CN, `zh-Hant` for zh-TW): **Sepia** in English and **纸质** in Simplified Chinese, never both side by side.

## Pull requests

- Title the pull request and its commits with a short sentence that says what changes, starting with a verb, e.g. "Fix Clear Margins on rotated pages".
- In the description, explain what changed and why and how you tested it, with before and after screenshots for visible changes.
- CI builds a universal app and a `.dmg` for every pull request; this **build** check has to pass. The `.dmg` is kept as a workflow artifact, so anyone can try the change.
- Leave the version number alone: release builds take it from the release tag.

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
