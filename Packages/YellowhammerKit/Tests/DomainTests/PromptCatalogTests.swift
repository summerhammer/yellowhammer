import CryptoKit
import Domain
import Foundation
import Testing

@Suite("PromptCatalog tests")
struct PromptCatalogTests {
    private struct PinRecord {
        let version: Int
        let sha256: String
    }

    private static let pinnedVersions: [PromptFamily: PinRecord] = [
        .selection: PinRecord(
            version: 1,
            sha256: "5db550452d8aa0e19286126eba730ebd9646531d712c23ac99a0c0d14a1dedf9"
        ),
        .breakdown: PinRecord(
            version: 1,
            sha256: "dfd9d78730508c8ac6ce178630a5273a42e9937496032706b0a435d349cb57c3"
        ),
        .architect: PinRecord(
            version: 1,
            sha256: "43e63579575b89410c16aca302a646dd077403de8e124396101000c8271d066d"
        ),
        .worker: PinRecord(
            version: 1,
            sha256: "96fe4d64934dd8a0f385db2eb54b900a168e72ec9565b14056ecd05a59f8e4cf"
        ),
        .reviewer: PinRecord(
            version: 1,
            sha256: "2dc1cbeee48a2992c56e5e2ca0d45b34a512bcbb91e3835d9ed451db4a426a54"
        ),
        .verifier: PinRecord(
            version: 2,
            sha256: "9c6d09f81491b4f6b6f29fff9a5462b649935c92dff30622d8975a5f0238e2fd"
        ),
        .unattendedProbe: PinRecord(
            version: 1,
            sha256: "512e0100fcdc8dca6218f9a6d42e0fe36b2e688d9e0ab08f02e79120cee30031"
        ),
        .sessionResumptionProbe: PinRecord(
            version: 1,
            sha256: "6713e662a023f25b3fa32272c54b7eed13f1e92a11391e95641197a7a3d9ccdf"
        ),
        .routePreflight: PinRecord(
            version: 1,
            sha256: "512e0100fcdc8dca6218f9a6d42e0fe36b2e688d9e0ab08f02e79120cee30031"
        ),
        .processContainmentProbe: PinRecord(
            version: 1,
            sha256: "c53be0b46171ff4ed3d2872a5ba356b28cc6c1db712f6f6cbc82b777207dc302"
        ),
        .stateContainmentProbe: PinRecord(
            version: 1,
            sha256: "201bdaf60e561bc3e3599d48a7ae722fcf120f1e9cd9b1cf0b8789214d6df7be"
        )
    ]

    @Test("Every prompt family has a catalog entry")
    func allFamiliesHaveEntries() {
        let families = PromptFamily.allCases
        let catalogFamilies = PromptCatalog.entries.map(\.family)
        #expect(catalogFamilies.count == families.count)
        for family in families {
            let entry = PromptCatalog.entry(for: family)
            #expect(entry != nil, "Missing entry for \(family)")
            #expect(entry?.defaultVersion == family.defaultVersion)
            #expect(entry?.acceptsProjectInstructions == family.acceptsProjectInstructions)
        }
    }

    @Test("Every template is non-empty and variants are populated")
    func nonEmtpyTemplates() {
        for entry in PromptCatalog.entries {
            #expect(!entry.variants.isEmpty, "Entry \(entry.family) has no variants")
            for variant in entry.variants {
                #expect(!variant.template.isEmpty, "Variant \(variant.name) of \(entry.family) is empty")
            }
        }
    }

    @Test("Every listed placeholder occurs in its template and is ordered by first appearance")
    func placeholdersOccurInTemplate() {
        for entry in PromptCatalog.entries {
            for variant in entry.variants {
                var lastOffset = 0
                for placeholder in variant.placeholders {
                    #expect(
                        variant.template.contains(placeholder),
                        "Placeholder \(placeholder) not found in template for \(entry.family) (\(variant.name))"
                    )
                    if let range = variant.template.range(of: placeholder) {
                        let offset = variant.template.distance(from: variant.template.startIndex, to: range.lowerBound)
                        #expect(
                            offset >= lastOffset,
                            "Placeholder \(placeholder) out of order in \(entry.family) (\(variant.name))"
                        )
                        lastOffset = offset
                    }
                }
            }
        }
    }

    @Test("Each diagnostic template equals the DiagnosticInstruction output")
    func diagnosticTemplatesMatchDiagnosticInstruction() {
        let unattended = PromptCatalog.entry(for: .unattendedProbe)?.variants.first?.template
        #expect(unattended == DiagnosticInstruction.unattended(nonce: "⟨nonce⟩"))

        let resume = PromptCatalog.entry(for: .sessionResumptionProbe)?.variants.first?.template
        #expect(resume == DiagnosticInstruction.resume)

        let preflight = PromptCatalog.entry(for: .routePreflight)?.variants.first?.template
        #expect(preflight == DiagnosticInstruction.unattended(nonce: "⟨nonce⟩"))

        let containment = PromptCatalog.entry(for: .processContainmentProbe)?.variants.first?.template
        #expect(containment == DiagnosticInstruction.containment(variant: "⟨variant⟩"))

        let stateContainment = PromptCatalog.entry(for: .stateContainmentProbe)?.variants.first?.template
        #expect(stateContainment == DiagnosticInstruction.stateContainment)
    }

    @Test("Prompt family version pin test")
    func versionPins() {
        for family in PromptFamily.allCases {
            guard let pin = Self.pinnedVersions[family] else {
                Issue.record("Missing pinned version for family \(family)")
                continue
            }
            guard let entry = PromptCatalog.entry(for: family) else {
                Issue.record("Missing catalog entry for family \(family)")
                continue
            }
            let joined = entry.variants.map(\.template).joined()
            let digest = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()

            if digest != pin.sha256 {
                if family.defaultVersion == pin.version {
                    Issue.record(
                        """
                        Prompt family \(family) shipped text changed without bumping PromptFamily.defaultVersion. \
                        Bump PromptFamily.defaultVersion for \(family) and update the pinned digest to \(digest).
                        """
                    )
                } else {
                    Issue.record(
                        """
                        Prompt family \(family) pinned digest does not match. Update the pinned digest to \(digest).
                        """
                    )
                }
            } else {
                #expect(family.defaultVersion == pin.version, "defaultVersion for \(family) changed but text did not")
            }
        }
    }
}
