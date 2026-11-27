import Foundation
import PithMacCore
import XCTest

final class DesignRulesTests: XCTestCase {
    private struct Source {
        let path: String
        let lines: [String]
    }

    private func sources() throws -> [Source] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Swift sources found under \(root.path)")
        return try files.map { url in
            Source(path: url.lastPathComponent, lines: try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n"))
        }
    }

    private func violations(_ pattern: String, in sources: [Source], allow: (Source, NSTextCheckingResult, String) -> Bool) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var found: [String] = []
        for source in sources {
            for (index, line) in source.lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                for match in regex.matches(in: line, range: range) where !allow(source, match, line) {
                    found.append("\(source.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return found
    }

    func testTextSizesComeFromTheTypeScale() throws {
        let found = try violations(#"Typography\.(ui|mono)\(\s*([0-9]+(?:\.[0-9]+)?)"#, in: try sources()) { _, match, line in
            let family = (line as NSString).substring(with: match.range(at: 1))
            let size = CGFloat(Double((line as NSString).substring(with: match.range(at: 2))) ?? -1)
            return family == "ui" ? TypeScale.sans.contains(size) : TypeScale.mono.contains(size)
        }
        XCTAssertEqual(found, [], "use a size from TypeScale (docs/DESIGN.md)")
    }

    func testColoursComeOnlyFromTheTheme() throws {
        let pattern = #"(Color|NSColor)\((hex|red|srgbRed|white|calibratedRed):|Color\.(white|black)\b|NSColor\.(white|black)\b"#
        let found = try violations(pattern, in: try sources()) { source, _, _ in source.path == "Theme.swift" }
        XCTAssertEqual(found, [], "add a token to Theme instead (docs/DESIGN.md)")
    }

    func testIconsAreDrawnNotSystemSymbols() throws {
        let found = try violations(#"Image\(systemName:|\.system\(size:"#, in: try sources()) { _, _, _ in false }
        XCTAssertEqual(found, [], "draw icons in Icons.swift and use Typography fonts (docs/DESIGN.md)")
    }

    func testScreensBuildFromSharedComponents() throws {
        let sources = try sources()
        let grids = try violations(#"LazyVGrid\("#, in: sources) { source, _, _ in source.path == "Components.swift" }
        XCTAssertEqual(grids, [], "use AdaptiveGrid so columns collapse when narrow (docs/DESIGN.md)")
        let keycaps = try violations(#"struct \w*Key(cap|Hint)\w*\b"#, in: sources) { source, _, _ in source.path == "Components.swift" }
        XCTAssertEqual(keycaps, [], "use Keycap / KeycapRow from Components.swift (docs/DESIGN.md)")
        let titles = try violations(#"TypeScale\.pageTitle"#, in: sources) { source, _, _ in source.path == "Components.swift" }
        XCTAssertEqual(titles, [], "use ScreenHeader or ScreenTitle (docs/DESIGN.md)")
    }

    func testTheTypeScaleMatchesTheDocumentedSteps() {
        XCTAssertEqual(TypeScale.sans, [11, 12, 13, 14, 15, 17, 22, 28])
        XCTAssertEqual(TypeScale.mono, [13.5])
    }

    func testOnlyKeyRouterInstallsGlobalKeyMonitors() throws {
        let found = try violations(#"addLocalMonitorForEvents"#, in: try sources()) { source, _, _ in
            source.path == "KeyRouting.swift"
        }
        XCTAssertEqual(found, [], "install keyboard handlers via .keyScope(...) instead of NSEvent monitors (docs/DESIGN.md)")
    }

    func testViewsDoNotMatchRawKeyCodes() throws {
        let found = try violations(#"\.keyCode\s*==|switch\s+[^.\n]*\.keyCode\b"#, in: try sources()) { source, _, _ in
            source.path == "KeyRouting.swift"
        }
        XCTAssertEqual(found, [], "match on KeyStroke.key or ShortcutStore instead of raw keyCodes (docs/DESIGN.md)")
    }

    func testMenusUseDynamicShortcutsFromShortcutStore() throws {
        let found = try violations(#"\.keyboardShortcut\("#, in: try sources()) { source, _, line in
            if source.path == "PithMacApp.swift" {
                return line.contains(#""z""#) || line.contains("self.keyboardShortcut(shortcut)")
            }
            return false
        }
        XCTAssertEqual(found, [], "use .dynamicShortcut(_:in:) backed by ShortcutStore so shortcuts stay customizable")
    }
}
