import AppKit
import Foundation

@MainActor
final class GitHubUpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, url: URL)
        case failed
    }

    @Published private(set) var status: Status = .idle

    let repositoryURL = URL(string: "https://github.com/Kymorphius/PAPower")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    func check() {
        guard status != .checking else { return }
        status = .checking

        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/Kymorphius/PAPower/releases/latest")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PAPower/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    status = .failed
                    return
                }

                let release = try JSONDecoder().decode(LatestRelease.self, from: data)
                let latestVersion = normalizedVersion(release.tagName)
                guard let releaseURL = URL(string: release.htmlURL) else {
                    status = .failed
                    return
                }

                if latestVersion.compare(
                    normalizedVersion(currentVersion),
                    options: .numeric
                ) == .orderedDescending {
                    status = .updateAvailable(version: latestVersion, url: releaseURL)
                } else {
                    status = .upToDate
                }
            } catch {
                status = .failed
            }
        }
    }

    func openRelease(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openRepository() {
        NSWorkspace.shared.open(repositoryURL)
    }

    private func normalizedVersion(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }
}

private struct LatestRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
