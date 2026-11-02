import AppKit
import Foundation
import Security

/// Installs the separately signed icon variant without modifying a signed bundle.
@MainActor enum AppIconInstaller {
    enum Failure: LocalizedError {
        case busy, missingVariant, invalidVariant, notWritable
        var errorDescription: String? {
            switch self {
            case .busy: return L("icon.switch.busy", "请等待文件操作完成后再切换图标。")
            case .missingVariant: return L("icon.switch.missing", "未找到当前版本的图标安装包，请重新安装 LeafFiles。")
            case .invalidVariant: return L("icon.switch.invalid", "图标安装包校验失败，当前应用未更改。")
            case .notWritable: return L("icon.switch.permission", "应用所在文件夹不可写，请将 LeafFiles 移到可写入的应用程序文件夹。")
            }
        }
    }

    static func installedChoice(bundle: Bundle = .main) -> AppIconChoice {
        bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "ClassicAppIcon" ? .original : .green
    }

    @discardableResult
    static func switchIfNeeded(to choice: AppIconChoice) throws -> Bool {
        guard choice != installedChoice() else { return false }
        guard !AppUpdatePolicy.hasActiveFileOperations(in: TabManager.allModels) else { throw Failure.busy }
        let fm = FileManager.default
        let app = Bundle.main.bundleURL.standardizedFileURL
        let parent = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw Failure.notWritable }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        guard build.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw Failure.invalidVariant }
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LeafFiles/IconVariants/\(build)", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let green = support.appendingPathComponent("Green.app", isDirectory: true)
        let stage = parent.appendingPathComponent(".leaffiles-icon-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var scheduled = false
        defer { if !scheduled { try? fm.removeItem(at: stage) } }

        let source: URL
        if choice == .original {
            guard let archive = Bundle.main.url(forResource: "ClassicVariant", withExtension: "zip") else { throw Failure.missingVariant }
            guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]),
                  run("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path]) else { throw Failure.invalidVariant }
            source = stage.appendingPathComponent("LeafFiles.app")
            // A green backup of this exact build is required for switching back.
            if fm.fileExists(atPath: green.path) { try fm.removeItem(at: green) }
            guard run("/usr/bin/ditto", ["--noextattr", "--norsrc", app.path, green.path]) else { throw Failure.invalidVariant }
        } else {
            guard fm.fileExists(atPath: green.path) else { throw Failure.missingVariant }
            source = stage.appendingPathComponent("LeafFiles.app")
            guard run("/usr/bin/ditto", ["--noextattr", "--norsrc", green.path, source.path]) else { throw Failure.invalidVariant }
        }
        guard let candidate = Bundle(url: source), candidate.bundleIdentifier == Bundle.main.bundleIdentifier,
              candidate.object(forInfoDictionaryKey: "CFBundleVersion") as? String == build,
              installedChoice(bundle: candidate) == choice,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path]),
              hasSameSigningRequirement(source, as: app) else { throw Failure.invalidVariant }

        let backup = stage.appendingPathComponent("previous.app")
        let shell = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        if /bin/mv "$2" "$3" && /bin/mv "$4" "$2"; then
          /usr/bin/touch "$2"
          /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$2" >/dev/null 2>&1 || true
          if /usr/bin/open "$2"; then exit 0; fi
          /bin/mv "$2" "$4" || exit 1
        fi
        /bin/mv "$3" "$2" 2>/dev/null || true
        /usr/bin/open "$2" >/dev/null 2>&1 || true
        exit 1
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shell, "icon-switch", String(ProcessInfo.processInfo.processIdentifier), app.path, backup.path, source.path]
        try process.run()
        scheduled = true
        return true
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }

    private static func hasSameSigningRequirement(_ candidate: URL, as current: URL) -> Bool {
        var currentCode: SecStaticCode?
        var candidateCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &currentCode) == errSecSuccess,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let currentCode, let candidateCode,
              SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        if SecStaticCodeCheckValidity(candidateCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess {
            return true
        }
        // Ad-hoc designated requirements contain the executable's cdhash, which
        // necessarily differs when the Info.plist icon changes. Compare the
        // unsigned executable contents only when *both* bundles are ad-hoc.
        func isAdHoc(_ code: SecStaticCode) -> Bool {
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let info = information as? [String: Any],
                  let flags = info[kSecCodeInfoFlags as String] as? NSNumber else { return false }
            return flags.uint32Value & 0x0002 != 0 // kSecCodeSignatureAdhoc
        }
        guard isAdHoc(currentCode), isAdHoc(candidateCode) else { return false }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("leaf-icon-verify-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temporary) }
            let a = temporary.appendingPathComponent("current")
            let b = temporary.appendingPathComponent("candidate")
            try fm.copyItem(at: current.appendingPathComponent("Contents/MacOS/WinFile"), to: a)
            try fm.copyItem(at: candidate.appendingPathComponent("Contents/MacOS/WinFile"), to: b)
            guard run("/usr/bin/codesign", ["--remove-signature", a.path]),
                  run("/usr/bin/codesign", ["--remove-signature", b.path]) else { return false }
            return try Data(contentsOf: a, options: .mappedIfSafe) == Data(contentsOf: b, options: .mappedIfSafe)
        } catch { return false }
    }
}
