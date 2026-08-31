import AppKit
import Darwin
import Foundation

struct ActiveApp: Identifiable {
    let id: String
    let name: String
    let cpuPercent: Double
    let processCount: Int
    let icon: NSImage?
    let isSystemService: Bool
}

@MainActor
final class ProcessActivitySampler {
    private struct Metadata {
        let key: String
        let name: String
        let icon: NSImage?
        let isSystemService: Bool
    }

    private struct Aggregate {
        let metadata: Metadata
        var cpuPercent: Double
        var processCount: Int
    }

    private let minimumRefreshInterval: TimeInterval = 5
    private var lastCaptureTimestamp: TimeInterval?
    private var cachedActivities: [ActiveApp] = []
    private var metadataCache: [String: Metadata] = [:]

    func capture(limit: Int = 5, force: Bool = false) -> [ActiveApp] {
        let now = ProcessInfo.processInfo.systemUptime
        if !force,
           let lastCaptureTimestamp,
           now - lastCaptureTimestamp < minimumRefreshInterval {
            return Array(cachedActivities.prefix(limit))
        }

        guard let processActivity = recentCPUActivity() else {
            return Array(cachedActivities.prefix(limit))
        }
        lastCaptureTimestamp = now

        var groups: [String: Aggregate] = [:]
        for activity in processActivity where activity.pid > 1 && activity.pid != getpid() {
            guard let metadata = metadata(for: activity.pid) else { continue }
            if var existing = groups[metadata.key] {
                existing.cpuPercent += activity.cpuPercent
                existing.processCount += 1
                groups[metadata.key] = existing
            } else {
                groups[metadata.key] = Aggregate(
                    metadata: metadata,
                    cpuPercent: activity.cpuPercent,
                    processCount: 1
                )
            }
        }

        cachedActivities = groups.values
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .map { aggregate in
                ActiveApp(
                    id: aggregate.metadata.key,
                    name: aggregate.metadata.name,
                    cpuPercent: aggregate.cpuPercent,
                    processCount: aggregate.processCount,
                    icon: aggregate.metadata.icon,
                    isSystemService: aggregate.metadata.isSystemService
                )
            }
        return Array(cachedActivities.prefix(limit))
    }

    /// `proc_pidinfo` hides CPU time for several important system services
    /// (WindowServer and coreaudiod, for example). `ps` can still expose a
    /// useful CPU average over roughly the previous minute for those processes
    /// without elevated access.
    /// Throttling this snapshot to once every five seconds keeps its overhead
    /// negligible while still making the popup useful.
    private func recentCPUActivity() -> [(pid: pid_t, cpuPercent: Double)]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,comm="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard columns.count >= 2,
                  let pid = pid_t(String(columns[0])),
                  let cpuPercent = Double(columns[1]),
                  cpuPercent >= 0.5,
                  cpuPercent.isFinite else {
                return nil
            }
            return (pid, cpuPercent)
        }
    }

    private func metadata(for pid: pid_t) -> Metadata? {
        let path = executablePath(for: pid)
        let fallbackName = processName(for: pid)
        guard path != nil || fallbackName != nil else { return nil }

        let cacheKey = path ?? "process:\(fallbackName!)"
        if let cached = metadataCache[cacheKey] {
            return cached
        }

        let metadata: Metadata
        if let path, let applicationPath = rootApplicationPath(in: path) {
            let bundle = Bundle(path: applicationPath)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: applicationPath).deletingPathExtension().lastPathComponent
            metadata = Metadata(
                key: "app:\(applicationPath)",
                name: name,
                icon: NSWorkspace.shared.icon(forFile: applicationPath),
                isSystemService: false
            )
        } else {
            let executableName = path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? fallbackName
                ?? "未知进程"
            metadata = systemMetadata(for: executableName, path: path)
        }

        metadataCache[cacheKey] = metadata
        return metadata
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    private func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_name(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return String(cString: baseAddress)
        }
    }

    private func rootApplicationPath(in executablePath: String) -> String? {
        var components: [String] = []
        for component in URL(fileURLWithPath: executablePath).pathComponents {
            components.append(component)
            if component.lowercased().hasSuffix(".app") {
                return NSString.path(withComponents: components)
            }
        }
        return nil
    }

    private func systemMetadata(for executableName: String, path: String?) -> Metadata {
        let lowercasedName = executableName.lowercased()
        let friendly: (key: String, name: String, symbol: String)?

        if lowercasedName == "mds"
            || lowercasedName.hasPrefix("mds_")
            || lowercasedName.hasPrefix("mdworker")
            || lowercasedName == "corespotlightd" {
            friendly = ("system:spotlight", "Spotlight 索引", "magnifyingglass")
        } else if lowercasedName == "windowserver" {
            friendly = ("system:windowserver", "窗口与显示", "macwindow")
        } else if lowercasedName == "coreaudiod" {
            friendly = ("system:audio", "音频服务", "speaker.wave.2.fill")
        } else if lowercasedName.hasPrefix("vtdecoder") || lowercasedName.hasPrefix("vtencoder") {
            friendly = ("system:video", "视频编解码", "play.rectangle.fill")
        } else if lowercasedName == "sysmond" {
            friendly = ("system:monitor", "系统监控", "gauge.with.dots.needle.67percent")
        } else if lowercasedName == "duetexpertd" {
            friendly = ("system:duet", "系统后台智能服务", "sparkles")
        } else if lowercasedName.hasPrefix("xprotect") {
            friendly = ("system:xprotect", "系统安全扫描", "checkmark.shield.fill")
        } else if lowercasedName == "loginitems" {
            friendly = ("system:login-items", "登录项设置", "person.crop.circle.badge.checkmark")
        } else if lowercasedName.contains("applebcmwlan") {
            friendly = ("system:wifi", "Wi-Fi 驱动", "wifi")
        } else if lowercasedName.contains("webkit") {
            friendly = ("system:web-content", "网页内容", "safari.fill")
        } else {
            friendly = nil
        }

        if let friendly {
            return Metadata(
                key: friendly.key,
                name: friendly.name,
                icon: systemImage(named: friendly.symbol),
                isSystemService: true
            )
        }

        let isSystem = path?.hasPrefix("/System/") == true
            || path?.hasPrefix("/usr/") == true
            || path?.hasPrefix("/sbin/") == true
        return Metadata(
            key: "process:\(path ?? executableName)",
            name: executableName,
            icon: systemImage(named: isSystem ? "gearshape.2.fill" : "terminal.fill"),
            isSystemService: isSystem
        )
    }

    private func systemImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}
