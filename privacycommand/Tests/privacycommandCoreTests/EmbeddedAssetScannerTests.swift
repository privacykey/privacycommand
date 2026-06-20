import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 5 — embedded assets: only flag scripts the bundle is actually prepared
/// to RUN (executable or shebang'd), parse shebangs by interpreter basename,
/// and require a real program before calling a plist a launchd job.
final class EmbeddedAssetScannerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ea-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ contents: String, executable: Bool = false) throws {
        let u = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: u)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
    }
    private func writePlist(_ name: String, _ d: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent(name))
    }
    private func bundle() -> AppBundle {
        AppBundle(url: dir, bundleID: "t", bundleName: "T", bundleVersion: "1",
                  executableURL: dir.appendingPathComponent("T"), architectures: [], minimumSystemVersion: nil)
    }

    func testOnlyRunnableScriptsAreFlagged() throws {
        try write("web.js", "console.log(1)")                          // inert resource — NOT runnable
        try write("lib.py", "import os")                               // inert library — NOT runnable
        try write("run.sh", "#!/bin/bash\necho hi", executable: true)  // executable + shebang
        try write("tool.py", "#!/usr/bin/env python3\nprint(1)")       // shebang, not +x
        try write("weird", "#!/opt/sh-tools/customlang\n", executable: true)

        let scripts = EmbeddedAssetScanner.scan(bundle: bundle()).scripts
        let names = Set(scripts.map { $0.url.lastPathComponent })

        XCTAssertFalse(names.contains("web.js"), "inert web .js must not be flagged as a runnable script")
        XCTAssertFalse(names.contains("lib.py"), "inert library .py must not be flagged")
        XCTAssertTrue(names.contains("run.sh"))
        XCTAssertTrue(names.contains("tool.py"))
        XCTAssertTrue(names.contains("weird"))
    }

    func testShebangParsedByInterpreterBasenameNotSubstring() throws {
        try write("envpy", "#!/usr/bin/env python3 -u\nprint(1)", executable: true)
        try write("weird", "#!/opt/sh-tools/customlang\n", executable: true)
        let scripts = EmbeddedAssetScanner.scan(bundle: bundle()).scripts

        XCTAssertEqual(scripts.first { $0.url.lastPathComponent == "envpy" }?.kind, .python,
                       "env-indirected python3 resolves to Python")
        let weird = scripts.first { $0.url.lastPathComponent == "weird" }?.kind
        if case .other = weird {} else {
            XCTFail("'/opt/sh-tools/customlang' must classify as .other, not .shell (old /sh substring bug)")
        }
    }

    func testLaunchPlistRequiresARealProgram() throws {
        try writePlist("good.plist", ["Label": "com.x.good",
                                      "ProgramArguments": ["/bin/echo", "hi"], "RunAtLoad": true])
        try writePlist("config.plist", ["Label": "com.x.config", "RunAtLoad": false])  // no program

        let labels = Set(EmbeddedAssetScanner.scan(bundle: bundle()).launchPlists.map(\.label))
        XCTAssertTrue(labels.contains("com.x.good"))
        XCTAssertFalse(labels.contains("com.x.config"),
                       "Label + RunAtLoad with no Program/ProgramArguments is not a launchd job")
    }

    func testNonExecutableShellScriptIsSurfaced() throws {
        // A 0644 shell script with no shebang is still something the app can run
        // via `bash x.sh` — it must be surfaced (the audit's false-negative case).
        try write("install.sh", "echo installing")
        let names = Set(EmbeddedAssetScanner.scan(bundle: bundle()).scripts.map { $0.url.lastPathComponent })
        XCTAssertTrue(names.contains("install.sh"))
        // But a non-exec, no-shebang Python LIBRARY stays suppressed (could be an
        // imported module / web asset, not a runnable entry point).
        try write("lib.py", "import os")
        let names2 = Set(EmbeddedAssetScanner.scan(bundle: bundle()).scripts.map { $0.url.lastPathComponent })
        XCTAssertFalse(names2.contains("lib.py"))
    }

    func testCRLFShebangClassifiedAsShell() throws {
        try write("run", "#!/bin/bash\r\necho hi", executable: true)
        let s = EmbeddedAssetScanner.scan(bundle: bundle()).scripts.first { $0.url.lastPathComponent == "run" }
        XCTAssertEqual(s?.kind, .shell, "a CRLF shebang must resolve to .shell, not .other(bash\\r)")
    }
}
