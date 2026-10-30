import Foundation

final class UpdateTestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    static var responseURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: Self.responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@main struct UpdateCheckTests {
    static func main() async throws {
        setbuf(stdout, nil)
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            print("\(value ? "PASS" : "FAIL") \(message)")
            if !value { failures += 1 }
        }
        func data(_ tag: String, draft: Bool = false, prerelease: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tag_name":tag,"draft":draft,"prerelease":prerelease,
                                                       "html_url":"https://example.invalid/untrusted"])
        }
        func rejected(_ data: Data, status: Int = 200) -> Bool {
            do { _ = try ReaderReleaseService.result(data:data,statusCode:status,currentVersion:"0.3.0"); return false }
            catch { return true }
        }
        check(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!, "numeric components do not sort lexicographically")
        check(ReleaseVersion("v1.2") == ReleaseVersion("1.2.0"), "release prefixes and omitted patch versions compare equally")
        check(["", "1..2", "vfoo", "1.2-beta", "1.2.3.4", "99999999999999999999999999"].allSatisfy { ReleaseVersion($0) == nil },
              "malformed and overflowing versions are rejected")
        let update = try ReaderReleaseService.result(data:data("v0.4.0"),statusCode:200,currentVersion:"0.3.0")
        check(update == .available(version:"v0.4.0",releaseURL:URL(string:"https://github.com/InkCitrus/Expert-PDF-Reader/releases/tag/v0.4.0")!),
              "a newer stable release links only to this repository's validated release tag")
        check(try ReaderReleaseService.result(data:data("v0.3.0"),statusCode:200,currentVersion:"0.3") == .current,
              "equal installed and published versions report no update")
        check(try ReaderReleaseService.result(data:data("v0.2.0"),statusCode:200,currentVersion:"0.3.0") == .current,
              "older releases never trigger a downgrade")
        check(try (rejected(data("v0.4.0",draft:true)) && rejected(data("v0.4.0",prerelease:true))),
              "drafts and prereleases cannot be offered as stable updates")
        check(try (rejected(Data("{}".utf8)) && rejected(data("unexpected"))), "invalid release data does not report up to date")
        check(try ReaderReleaseService.result(data:Data(),statusCode:404,currentVersion:"0.3.0") == .noRelease,
              "a repository without a release has a distinct result")
        check(rejected(Data(),status:403) && rejected(Data(),status:429) && rejected(Data(),status:500),
              "rate limits and server failures do not report up to date")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateTestProtocol.self]
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        var requestVerified = false
        UpdateTestProtocol.handler = { request in
            requestVerified = request.url == ReaderReleaseService.endpoint
                && request.value(forHTTPHeaderField:"Accept") == "application/vnd.github+json"
                && request.value(forHTTPHeaderField:"Authorization") == nil && request.timeoutInterval == 15
            return (200, try data("v0.4.0"))
        }
        check(try await ReaderReleaseService.check(currentVersion:"0.3.0",session:session) == update && requestVerified,
              "the asynchronous request checks the public endpoint with a timeout and no credentials")
        UpdateTestProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await ReaderReleaseService.check(currentVersion:"0.3.0",session:session)
            check(false,"offline requests fail explicitly")
        } catch { check(true,"offline requests fail explicitly") }
        UpdateTestProtocol.handler = { request in
            if request.url == ReaderReleaseService.endpoint { UpdateTestProtocol.responseURL = nil; return (403, Data()) }
            UpdateTestProtocol.responseURL = URL(string:"https://github.com/InkCitrus/Expert-PDF-Reader/releases/tag/v0.4.0")!
            return (200, Data())
        }
        check(try await ReaderReleaseService.check(currentVersion:"0.3.0",session:session) == update,
              "an exhausted anonymous API quota falls back to the official stable release redirect")
        UpdateTestProtocol.handler = { request in
            if request.url == ReaderReleaseService.endpoint { UpdateTestProtocol.responseURL = nil; return (403, Data()) }
            UpdateTestProtocol.responseURL = URL(string:"https://example.invalid/releases/tag/v0.4.0")!
            return (200, Data())
        }
        do { _ = try await ReaderReleaseService.check(currentVersion:"0.3.0",session:session)
            check(false,"fallback redirects cannot escape the official repository")
        } catch { check(true,"fallback redirects cannot escape the official repository") }
        if CommandLine.arguments.contains("--live") {
            let result = try await ReaderReleaseService.check(currentVersion:"0.3.0")
            print("Live public GitHub result: \(result)")
        }
        print(failures == 0 ? "All update checks passed" : "Update checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
