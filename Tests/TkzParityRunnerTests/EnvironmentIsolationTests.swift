// Environment isolation (WOR-322 S3; ADR-0002, ADR-0003 §3 "Determinism"): every enforced producer
// writes the same bytes whatever the desktop session around it says about scale, fonts or text size.
//
// Each enforced row's producer runs once from the clean base environment and once under each
// variant below, in a fresh child process, and every artifact must be byte-identical to the
// baseline's. The variants are the settings a Linux desktop really carries:
//
//   GDK_SCALE=2                 the integer scale GTK would apply
//   FREETYPE_PROPERTIES         FreeType's global hinting and stem-darkening switches, read when a
//                               library is created
//   50-omarchy.conf             Omarchy's fontconfig rules through FONTCONFIG_FILE: monospace and
//                               sans-serif reassigned, Noto Color Emoji accepted for them (the rule
//                               that resolves ✳ to an emoji). The installed file when present, else a
//                               stand-in with the same kinds of rules
//   text-scaling-factor 0.7273  GNOME's text scale, through a GSettings keyfile backend in a private
//                               XDG_CONFIG_HOME (the user's dconf is never touched)
//   all                         everything at once
//
// L1, L3 and L4 are covered as soon as their producers are registered and their rows enforced.
// Mismatches are reported under `.build/parity/isolation/<layer>@<scale>/<variant>/`.

import Foundation
import Testing
import TkzParity

struct IsolationVariant: Sendable {
    let name: String
    let environment: [String: String]
}

enum EnvironmentIsolation {
    /// The Omarchy file, where the omarchy-settings package installs it.
    static let omarchyConf = "/usr/share/fontconfig/conf.avail/50-omarchy.conf"

    /// The variants, with the files they point at written under `directory`.
    static func variants(in directory: URL) throws -> [IsolationVariant] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // FONTCONFIG_FILE replaces the whole configuration, so the system's comes first.
        let rules: String
        if FileManager.default.fileExists(atPath: omarchyConf) {
            rules = "<include ignore_missing=\"no\">\(omarchyConf)</include>"
        } else {
            let standIn = directory.appending(path: "omarchy-stand-in.conf")
            try """
                <?xml version="1.0"?>
                <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
                <fontconfig>
                  <match target="pattern">
                    <test name="family" qual="any"><string>monospace</string></test>
                    <edit name="family" mode="assign" binding="strong"><string>DejaVu Sans Mono</string></edit>
                  </match>
                  <match target="pattern">
                    <test name="family" qual="any"><string>sans-serif</string></test>
                    <edit name="family" mode="assign" binding="strong"><string>DejaVu Sans</string></edit>
                  </match>
                  <alias><family>monospace</family><accept><family>Noto Color Emoji</family></accept></alias>
                  <alias><family>sans-serif</family><accept><family>Noto Color Emoji</family></accept></alias>
                </fontconfig>

                """.write(to: standIn, atomically: true, encoding: .utf8)
            rules = "<include ignore_missing=\"no\">\(standIn.path)</include>"
        }
        let fontsConf = directory.appending(path: "fonts.conf")
        try """
            <?xml version="1.0"?>
            <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
            <fontconfig>
              <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
              \(rules)
            </fontconfig>

            """.write(to: fontsConf, atomically: true, encoding: .utf8)

        let configHome = directory.appending(path: "config", directoryHint: .isDirectory)
        let keyfile = configHome.appending(path: "glib-2.0/settings/keyfile")
        try FileManager.default.createDirectory(at: keyfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[org/gnome/desktop/interface]\ntext-scaling-factor=0.7273\n".write(to: keyfile, atomically: true, encoding: .utf8)

        let gdk = ["GDK_SCALE": "2"]
        let freetype = ["FREETYPE_PROPERTIES": "truetype:interpreter-version=35 cff:no-stem-darkening=0 "
                        + "autofitter:no-stem-darkening=0 autofitter:darkening-parameters=500,0,1000,500,2500,500,4000,0"]
        let fontconfig = ["FONTCONFIG_FILE": fontsConf.path]
        let textScale = ["GSETTINGS_BACKEND": "keyfile", "XDG_CONFIG_HOME": configHome.path]
        let all = [gdk, freetype, fontconfig, textScale].reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
        return [
            IsolationVariant(name: "GDK_SCALE=2", environment: gdk),
            IsolationVariant(name: "FREETYPE_PROPERTIES", environment: freetype),
            IsolationVariant(name: "50-omarchy.conf", environment: fontconfig),
            IsolationVariant(name: "text-scaling-factor-0.7273", environment: textScale),
            IsolationVariant(name: "all", environment: all),
        ]
    }

    static func environment(_ variant: IsolationVariant) -> [String: String] {
        ParityEnvironment.base.merging(variant.environment) { _, new in new }
    }

    /// Every regular file under `directory`, by relative path.
    static func files(under directory: URL) -> [String: URL] {
        var found: [String: URL] = [:]
        let base = directory.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            found[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = url
        }
        return found
    }
}

@Suite struct EnvironmentIsolationTests {
    @Test("every enforced producer ignores the desktop environment", arguments: ParityRunner.enforcedRows)
    func producerIsIsolated(_ row: LayerManifest.Row) throws {
        let producer = try #require(ParityProducers.registry[row.layer], "\(row.layer) is enforced without a producer")
        if let missing = producer.missingReferences(row.scale) {
            // Nothing to compare yet; the runner reports the skip.
            print("isolation \(row.layer)@\(row.scale): skipped, references missing: \(missing)")
            return
        }
        let root = try ParityPaths.freshDirectory("isolation", ParityPaths.rowName(row.layer, row.scale))
        func produce(_ name: String, _ environment: [String: String]) throws -> [String: URL] {
            let output = root.appending(path: name, directoryHint: .isDirectory)
            let produced = output.appending(path: "produced", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: produced, withIntermediateDirectories: true)
            _ = try producer.produce(ProducerContext(scale: row.scale, environment: environment, output: produced,
                                                     log: output.appending(path: "producer.log")))
            return EnvironmentIsolation.files(under: produced)
        }

        let baseline = try produce("baseline", ParityEnvironment.base)
        #expect(!baseline.isEmpty, "the \(row.layer) producer wrote nothing")
        for variant in try EnvironmentIsolation.variants(in: root.appending(path: "inputs", directoryHint: .isDirectory)) {
            let files = try produce(variant.name, EnvironmentIsolation.environment(variant))
            #expect(Set(files.keys) == Set(baseline.keys), "\(row.layer)@\(row.scale) under \(variant.name): different files")
            for (name, url) in baseline.sorted(by: { $0.key < $1.key }) {
                guard let other = files[name] else { continue }
                var report = ByteComparison.compare(try [UInt8](Data(contentsOf: url)), try [UInt8](Data(contentsOf: other)), json: false)
                guard !report.identical else { continue }
                report.a = url.path
                report.b = other.path
                try ParityReports.writeJSON(report, to: root.appending(path: "\(variant.name)/reports/\(name).json"))
                Issue.record("\(row.layer)@\(row.scale) under \(variant.name): \(name) differs from the baseline at byte \(report.firstDifference ?? 0)")
            }
        }
        print("isolation \(row.layer)@\(row.scale): \(baseline.count) artifacts byte-identical under every variant")
    }

    /// The variants reach the child, and the display does not.
    @Test func theVariantsReachTheChild() throws {
        let root = try ParityPaths.freshDirectory("selftest", "isolation-env")
        let variants = try EnvironmentIsolation.variants(in: root)
        let all = try #require(variants.first { $0.name == "all" })
        var environment = EnvironmentIsolation.environment(all)
        #expect(environment["WAYLAND_DISPLAY"] == nil && environment["DISPLAY"] == nil)
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin"
        let log = root.appending(path: "env.txt")
        let outcome = try ParityProcess.run(URL(fileURLWithPath: "/usr/bin/env"), [], environment: environment, log: log)
        #expect(outcome.status == 0)
        let lines = Set(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init))
        for (key, value) in all.environment {
            #expect(lines.contains("\(key)=\(value)"), "\(key) did not reach the child")
        }
        #expect(!lines.contains { $0.hasPrefix("WAYLAND_DISPLAY=") || $0.hasPrefix("DISPLAY=") })
        #expect(variants.map(\.name) == ["GDK_SCALE=2", "FREETYPE_PROPERTIES", "50-omarchy.conf",
                                         "text-scaling-factor-0.7273", "all"])
    }

    /// With GSettings installed, the keyfile backend really reports the 0.7273 text scale.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/gsettings")
                   && FileManager.default.fileExists(atPath: "/usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml"),
                   "needs gsettings and the org.gnome.desktop.interface schema"))
    func theTextScaleVariantIsWhatGSettingsReads() throws {
        let root = try ParityPaths.freshDirectory("selftest", "isolation-gsettings")
        let variant = try #require(try EnvironmentIsolation.variants(in: root).first { $0.name.hasPrefix("text-scaling-factor") })
        let log = root.appending(path: "gsettings.txt")
        let outcome = try ParityProcess.run(URL(fileURLWithPath: "/usr/bin/gsettings"),
                                            ["get", "org.gnome.desktop.interface", "text-scaling-factor"],
                                            environment: EnvironmentIsolation.environment(variant), log: log)
        #expect(outcome.status == 0, "\(outcome.tail)")
        // GVariant prints the double with 17 digits: 0.72729999999999995.
        let printed = try String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Double(printed) == 0.7273, "gsettings read \(printed)")
    }
}
