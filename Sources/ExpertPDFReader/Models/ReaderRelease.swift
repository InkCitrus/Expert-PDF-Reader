import Foundation

/// Release tags and bundle versions use one to three numeric components, as in the release workflow.
struct ReleaseVersion: Comparable, Sendable {
    private let components: [Int]

    init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

enum ReaderUpdateResult: Equatable, Sendable {
    case available(version: String, releaseURL: URL)
    case current
    case noRelease
}

enum ReaderUpdateError: Error { case invalidResponse, rateLimited }

enum ReaderReleaseService {
    static let projectURL = URL(string: "https://github.com/InkCitrus/Expert-PDF-Reader")!
    static let endpoint = URL(string: "https://api.github.com/repos/InkCitrus/Expert-PDF-Reader/releases/latest")!

    private struct Release: Codable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    static func result(data: Data, statusCode: Int, currentVersion: String) throws -> ReaderUpdateResult {
        if statusCode == 404 { return .noRelease }
        if statusCode == 403 || statusCode == 429 { throw ReaderUpdateError.rateLimited }
        guard statusCode == 200, let installed = ReleaseVersion(currentVersion),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease, let published = ReleaseVersion(release.tag_name) else {
            throw ReaderUpdateError.invalidResponse
        }
        guard published > installed else { return .current }
        // Build the destination from our repository and a validated tag; ignore arbitrary URLs in the feed.
        return .available(version: release.tag_name,
                          releaseURL: projectURL.appendingPathComponent("releases/tag").appendingPathComponent(release.tag_name))
    }

    static func check(currentVersion: String, session: URLSession = .shared) async throws -> ReaderUpdateResult {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Expert-PDF-Reader/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReaderUpdateError.invalidResponse }
        if response.statusCode == 403 || response.statusCode == 429 {
            // Shared networks can exhaust the anonymous API quota. GitHub's public latest-release
            // redirect still resolves to the official stable release without a token or HTML scraping.
            var fallback = URLRequest(url: projectURL.appendingPathComponent("releases/latest"),
                                      cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            fallback.httpMethod = "HEAD"
            fallback.setValue("Expert-PDF-Reader/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (_, redirected) = try await session.data(for: fallback)
            guard let redirected = redirected as? HTTPURLResponse, redirected.statusCode == 200,
                  let url = redirected.url, url.scheme == "https", url.host == "github.com",
                  url.deletingLastPathComponent().path == projectURL.path + "/releases/tag" else {
                throw ReaderUpdateError.rateLimited
            }
            let release = try JSONEncoder().encode(Release(tag_name: url.lastPathComponent, draft: false, prerelease: false))
            return try result(data: release, statusCode: 200, currentVersion: currentVersion)
        }
        return try result(data: data, statusCode: response.statusCode, currentVersion: currentVersion)
    }
}
