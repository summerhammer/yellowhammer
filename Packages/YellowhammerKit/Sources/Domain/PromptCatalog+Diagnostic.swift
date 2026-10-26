import Foundation

extension PromptCatalog {
    static var unattendedProbeEntry: PromptCatalogEntry {
        let template = DiagnosticInstruction.unattended(nonce: "⟨nonce⟩")
        let variant = makeVariant(name: "Default", template: template, candidatePlaceholders: ["⟨nonce⟩"])
        return PromptCatalogEntry(
            family: .unattendedProbe,
            title: "Unattended probe",
            purpose: "Tests whether an agent CLI can run unattended and report "
                + "a failure outcome without interactive prompts.",
            defaultVersion: PromptFamily.unattendedProbe.defaultVersion,
            acceptsProjectInstructions: PromptFamily.unattendedProbe.acceptsProjectInstructions,
            variants: [variant]
        )
    }

    static var sessionResumptionProbeEntry: PromptCatalogEntry {
        let template = DiagnosticInstruction.resume
        let variant = makeVariant(name: "Default", template: template, candidatePlaceholders: [])
        return PromptCatalogEntry(
            family: .sessionResumptionProbe,
            title: "Session resumption probe",
            purpose: "Tests whether an agent CLI can resume an existing session and recall prior turn context.",
            defaultVersion: PromptFamily.sessionResumptionProbe.defaultVersion,
            acceptsProjectInstructions: PromptFamily.sessionResumptionProbe.acceptsProjectInstructions,
            variants: [variant]
        )
    }

    static var routePreflightEntry: PromptCatalogEntry {
        let template = DiagnosticInstruction.unattended(nonce: "⟨nonce⟩")
        let variant = makeVariant(name: "Default", template: template, candidatePlaceholders: ["⟨nonce⟩"])
        return PromptCatalogEntry(
            family: .routePreflight,
            title: "Route Pre-flight",
            purpose: "Reuses the unattended probe instruction to verify a configured Route before dispatch.",
            defaultVersion: PromptFamily.routePreflight.defaultVersion,
            acceptsProjectInstructions: PromptFamily.routePreflight.acceptsProjectInstructions,
            variants: [variant]
        )
    }

    static var processContainmentProbeEntry: PromptCatalogEntry {
        let template = DiagnosticInstruction.containment(variant: "⟨variant⟩")
        let variant = makeVariant(name: "Default", template: template, candidatePlaceholders: ["⟨variant⟩"])
        return PromptCatalogEntry(
            family: .processContainmentProbe,
            title: "Process containment probe",
            purpose: "Tests whether an agent CLI terminates cleanly and contains "
                + "descendant background processes upon cancellation.",
            defaultVersion: PromptFamily.processContainmentProbe.defaultVersion,
            acceptsProjectInstructions: PromptFamily.processContainmentProbe.acceptsProjectInstructions,
            variants: [variant]
        )
    }

    static var stateContainmentProbeEntry: PromptCatalogEntry {
        let template = DiagnosticInstruction.stateContainment
        let variant = makeVariant(name: "Default", template: template, candidatePlaceholders: [])
        return PromptCatalogEntry(
            family: .stateContainmentProbe,
            title: "State containment probe",
            purpose: "Tests whether an agent CLI respects read-only sandbox boundaries "
                + "and avoids leaking credentials or state.",
            defaultVersion: PromptFamily.stateContainmentProbe.defaultVersion,
            acceptsProjectInstructions: PromptFamily.stateContainmentProbe.acceptsProjectInstructions,
            variants: [variant]
        )
    }
}
