import Foundation
import SwiftUI

/// Supported application UI languages (`system`, `zh-Hans`, `en`).
public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    /// Whether this language mode resolves to Simplified Chinese
    public var resolvedIsChinese: Bool {
        switch self {
        case .zhHans:
            return true
        case .en:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh")
        }
    }

    public var locale: Locale {
        Locale(identifier: resolvedIsChinese ? "zh-Hans" : "en")
    }

    public var title: String {
        switch self {
        case .system:
            return L10n.tr("跟随系统", "Follow System")
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }

    public var shortTitle: String {
        switch self {
        case .system:
            return L10n.tr("自动", "Auto")
        case .zhHans:
            return "中文"
        case .en:
            return "EN"
        }
    }
}

/// Centralized reactive localization provider for **Expert PDF Reader**.
public enum L10n {
    /// Updated by `AppStore` whenever `appLanguage` changes; initialized from `UserDefaults`.
    public static var currentLanguage: AppLanguage = {
        let raw = UserDefaults.standard.string(forKey: "expertPDFReader.appLanguage")
            ?? UserDefaults.standard.string(forKey: "openPDFExpert.appLanguage")
            ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }()

    public static var isChinese: Bool {
        currentLanguage.resolvedIsChinese
    }

    /// Returns `zh` when the active language resolves to Chinese, otherwise `en`.
    public static func tr(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    public static func pageCountText(_ count: Int) -> String {
        isChinese ? "\(count) 页" : (count == 1 ? "1 page" : "\(count) pages")
    }

    public static func pageTitle(_ label: String) -> String {
        isChinese ? "第 \(label) 页" : "Page \(label)"
    }

    public static func jumpToPage(_ label: String) -> String {
        isChinese ? "跳转到第 \(label) 页" : "Go to Page \(label)"
    }

    public static func defaultBookmarkTitle(pageNumber: Int) -> String {
        isChinese ? "第 \(pageNumber) 页" : "Page \(pageNumber)"
    }

    public static func searchMatchSummary(current: Int, total: Int) -> String {
        isChinese
            ? "第 \(current) 处，共 \(total) 处匹配"
            : "\(current) of \(total) matches"
    }

    public static func searchNotFound(_ query: String) -> String {
        isChinese ? "未找到“\(query)”" : "No matches for “\(query)”"
    }

    public static func zoomPercentageAccessibility(_ percent: Int) -> String {
        isChinese ? "缩放比例 \(percent)%" : "Zoom \(percent)%"
    }

    public static func closeTabAccessibility(_ title: String) -> String {
        isChinese ? "关闭标签 \(title)" : "Close tab \(title)"
    }
}
