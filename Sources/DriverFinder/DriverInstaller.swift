import AppKit
import Foundation

struct VerifiedDriverPackage: Equatable {
    let packageURL: URL
    let isApp: Bool
    let signingIdentity: String
    let mountPoint: URL?
    let workDirectory: URL
}

enum DriverInstallError: Error, Equatable {
    case downloadFailed
    case tooLarge
    case noPackage
    case unsigned
    case installerFailed

    var message: String {
        switch self {
        case .downloadFailed: "Couldn’t download the driver"
        case .tooLarge: "The driver download is too large"
        case .noPackage: "The download has no installer"
        case .unsigned: "This installer isn’t notarized by Apple for a verified developer, so PrettyPrint won’t open it"
        case .installerFailed: "Couldn’t open the installer"
        }
    }
}

enum DriverInstaller {
    static let maximumDownloadBytes: Int64 = 2_000_000_000
    static let maximumExpandedBytes: Int64 = 4_000_000_000
    static let maximumArchiveEntries = 20_000

    static func prepare(from source: URL) async -> Result<VerifiedDriverPackage, DriverInstallError> {
        guard source.scheme == "https" else { return .failure(.downloadFailed) }
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrettyPrint-driver-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let file: URL
        switch await download(source, into: workDirectory) {
        case .success(let downloaded): file = downloaded
        case .failure(let error):
            await discard(mountPoint: nil, workDirectory: workDirectory)
            return .failure(error)
        }

        var mountPoint: URL?
        let searchRoot: URL
        switch file.pathExtension.lowercased() {
        case "pkg", "mpkg":
            searchRoot = workDirectory
        case "dmg":
            let mount = workDirectory.appendingPathComponent("mount", isDirectory: true)
            guard await ProcessRunner.run(
                "/usr/bin/hdiutil",
                ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path],
                timeout: 120
            )?.succeeded == true else {
                await discard(mountPoint: nil, workDirectory: workDirectory)
                return .failure(.noPackage)
            }
            mountPoint = mount
            searchRoot = mount
        case "zip":
            guard let listing = await ProcessRunner.output("/usr/bin/zipinfo", ["-t", file.path], timeout: 60),
                  archiveFitsLimits(zipinfoTotals: listing) else {
                await discard(mountPoint: nil, workDirectory: workDirectory)
                return .failure(.tooLarge)
            }
            let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
            guard await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", file.path, unpacked.path], timeout: 300)?.succeeded == true else {
                await discard(mountPoint: nil, workDirectory: workDirectory)
                return .failure(.noPackage)
            }
            searchRoot = unpacked
        default:
            await discard(mountPoint: nil, workDirectory: workDirectory)
            return .failure(.noPackage)
        }

        guard let installer = firstInstaller(in: searchRoot) else {
            await discard(mountPoint: mountPoint, workDirectory: workDirectory)
            return .failure(.noPackage)
        }
        let isApp = installer.pathExtension.lowercased() == "app"
        guard let signingIdentity = await notarizedIdentity(of: installer, isApp: isApp) else {
            await discard(mountPoint: mountPoint, workDirectory: workDirectory)
            return .failure(.unsigned)
        }
        return .success(VerifiedDriverPackage(
            packageURL: installer,
            isApp: isApp,
            signingIdentity: signingIdentity,
            mountPoint: mountPoint,
            workDirectory: workDirectory
        ))
    }

    static func identity(inGatekeeperOutput output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3,
              lines[0].hasSuffix(": accepted"),
              lines.contains("source=Notarized Developer ID"),
              let origin = lines.first(where: { $0.hasPrefix("origin=") }) else { return nil }
        let identity = String(origin.dropFirst("origin=".count))
        return identity.wholeMatch(of: #/Developer ID (Installer|Application): .+ \([A-Z0-9]{10}\)/#) == nil ? nil : identity
    }

    static func isSafePath(_ path: String) -> Bool {
        !path.contains(where: \.isNewline)
            && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    static func displayName(of identity: String) -> String {
        identity
            .replacingOccurrences(of: #"^Developer ID (Installer|Application): "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\([A-Z0-9]{10}\)$"#, with: "", options: .regularExpression)
    }

    static func archiveFitsLimits(zipinfoTotals output: String) -> Bool {
        guard let totals = output.split(whereSeparator: \.isNewline).last,
              let match = totals.firstMatch(of: #/^(\d+) files?, (\d+) bytes uncompressed/#),
              let entries = Int(match.1), let bytes = Int64(match.2) else { return false }
        return entries <= maximumArchiveEntries && bytes <= maximumExpandedBytes
    }

    @MainActor
    static func install(_ package: VerifiedDriverPackage) async -> Result<Void, DriverInstallError> {
        guard await notarizedIdentity(of: package.packageURL, isApp: package.isApp) == package.signingIdentity else {
            await discard(mountPoint: package.mountPoint, workDirectory: package.workDirectory)
            return .failure(.unsigned)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application: NSRunningApplication?
        if package.isApp {
            application = try? await NSWorkspace.shared.openApplication(at: package.packageURL, configuration: configuration)
        } else if let installer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.installer") {
            application = try? await NSWorkspace.shared.open([package.packageURL], withApplicationAt: installer, configuration: configuration)
        } else {
            application = nil
        }
        guard let application else {
            await discard(mountPoint: package.mountPoint, workDirectory: package.workDirectory)
            return .failure(.installerFailed)
        }
        while !application.isTerminated {
            try? await Task.sleep(for: .milliseconds(500))
        }
        await discard(mountPoint: package.mountPoint, workDirectory: package.workDirectory)
        return .success(())
    }

    static func discard(_ package: VerifiedDriverPackage) {
        Task { await discard(mountPoint: package.mountPoint, workDirectory: package.workDirectory) }
    }

    private static func discard(mountPoint: URL?, workDirectory: URL) async {
        if let mountPoint {
            _ = await ProcessRunner.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], timeout: 60)
        }
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private static func notarizedIdentity(of installer: URL, isApp: Bool) async -> String? {
        guard isSafePath(installer.path) else { return nil }
        let result = await ProcessRunner.run(
            "/usr/sbin/spctl",
            ["--assess", "--type", isApp ? "execute" : "install", "-vv", installer.path],
            timeout: 60
        )
        guard let result, result.succeeded else { return nil }
        return identity(inGatekeeperOutput: result.standardError)
    }

    private static func download(_ source: URL, into directory: URL) async -> Result<URL, DriverInstallError> {
        let limiter = DownloadLimiter(limit: maximumDownloadBytes)
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: source, delegate: limiter)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) <= maximumDownloadBytes else {
                try? FileManager.default.removeItem(at: downloaded)
                return .failure(limiter.exceeded ? .tooLarge : .downloadFailed)
            }
            let name = (response.suggestedFilename ?? source.lastPathComponent).replacingOccurrences(of: "/", with: "_")
            let file = directory.appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? "driver" : name)
            try FileManager.default.moveItem(at: downloaded, to: file)
            return .success(file)
        } catch {
            return .failure(limiter.exceeded ? .tooLarge : .downloadFailed)
        }
    }

    private static func firstInstaller(in root: URL) -> URL? {
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var installerApp: URL?
        while let url = enumerator?.nextObject() as? URL {
            if enumerator?.level ?? 0 > 3 { enumerator?.skipDescendants() }
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            guard !isLink, isSafePath(url.path), url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else { continue }
            let kind = url.pathExtension.lowercased()
            if kind == "pkg" || kind == "mpkg" { return url }
            if kind == "app", installerApp == nil { installerApp = url }
        }
        return installerApp
    }
}

private final class DownloadLimiter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let lock = NSLock()
    private var didExceed = false

    init(limit: Int64) {
        self.limit = limit
    }

    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceed
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > limit || totalBytesExpectedToWrite > limit else { return }
        lock.lock()
        didExceed = true
        lock.unlock()
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
