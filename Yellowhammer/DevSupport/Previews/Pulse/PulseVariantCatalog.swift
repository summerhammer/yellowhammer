#if DEBUG
import Pulse
import SwiftUI

// The variants in play, registered in `PulseVariant.all`. Most compose a `PulseDesign` from the
// section, Sidebar, toolbar and Inspector styles; see those files for what each style tries.

extension PulseVariant {
    /// The variants the Playground and Gallery offer. Every other variant stays in `all`, reachable by
    /// name from a `#Preview`, so a shelved idea can come back without being rewritten.
    static let shown: Set<String> = ["Strip and Cards"]

    /// The shown variants, in catalog order.
    static var inPlay: [PulseVariant] { all.filter { shown.contains($0.name) } }

    /// Every variant, shown or shelved.
    static let all: [PulseVariant] = [
        PulseVariant("Baseline", idea: "Plain three-column layout, the five groups as sections, in ruled order") {
            PulseBaselineVariant(snapshot: $0, selection: $1)
        },
        PulseVariant(
            "Settings Form",
            idea: "Grouped Form like System Settings; Inspector as Get Info; toolbar holds only the Inspector toggle",
            design: PulseDesign(sections: .grouped, toolbar: .minimal, inspector: .form)
        ),
//        PulseVariant(
//            "Dashboard",
//            idea: "Needs you full width, the rest as tiles; badged Sidebar; Night Card, Feature, Settings in toolbar",
//            design: PulseDesign(
//                sections: .dashboard, sidebar: .badged, toolbar: .waysOut, inspector: .header, opens: .feature
//            )
//        ),
        PulseVariant(
            "Tinted Cards",
            idea: "Each group a softly tinted card with a Settings-style icon; the Now line centred in the toolbar",
            design: PulseDesign(sections: .tinted, sidebar: .badged, toolbar: .status, inspector: .header)
        ),
        PulseVariant(
            "Mail List",
            idea: "Inset List with summary headers, two-line Sidebar, a filter field, and a dense Inspector",
            design: PulseDesign(sections: .list, sidebar: .twoLine, toolbar: .search, inspector: .compact)
        ),
        PulseVariant(
            "Summary Strip",
            idea: "Five figures on top jump to the detail below; the Inspector opens on the first running Attempt",
            design: PulseDesign(
                sections: .summaryStrip, sidebar: .twoLine, toolbar: .status, inspector: .form, opens: .attempt
            )
        ),
        PulseVariant(
            "Disclosure",
            idea: "Collapsible groups labelled with their summary; the window title carries the name and read time",
            design: PulseDesign(
                sections: .disclosure, sidebar: .badged, toolbar: .titled, inspector: .compact, opens: .nothing
            )
        ),
        PulseVariant(
            "Hero Banner",
            idea: "A banner tinted by the loudest state extends under the glass Sidebar and Inspector",
            design: PulseDesign(sections: .hero, toolbar: .waysOut, inspector: .header)
        ),
        PulseVariant(
            "Rail",
            idea: "A vertical rail with a coloured node per group; the Inspector opens on the lead Repo",
            design: PulseDesign(sections: .rail, sidebar: .twoLine, toolbar: .minimal, inspector: .form, opens: .repo)
        ),
        PulseVariant(
            "Glass Overlay",
            idea: "The Sidebar floats as a Liquid Glass panel over a full-width dashboard, toggled from the toolbar",
            design: PulseDesign(
                sections: .dashboard, sidebar: .badged, floatingGlassSidebar: true, toolbar: .titled,
                inspector: .header, opens: .feature
            )
        ),
        PulseVariant(
            "Glass over Hero",
            idea: "Floating glass Sidebar over the hero banner, so the tint reads through the glass",
            design: PulseDesign(
                sections: .hero, sidebar: .twoLine, floatingGlassSidebar: true, toolbar: .status,
                inspector: .compact, opens: .attempt
            )
        ),
        PulseVariant(
            "Glass Rail",
            idea: "Floating glass Sidebar over the rail, with a filter field for Cards and Attempts",
            design: PulseDesign(
                sections: .rail, sidebar: .sourceList, floatingGlassSidebar: true, toolbar: .search, inspector: .form
            )
        ),
        PulseVariant(
            "Tinted, Filterable",
            idea: "Tinted cards with a filter field; the Inspector opens on a Repo to show its lane, PR and Cards",
            design: PulseDesign(sections: .tinted, toolbar: .search, inspector: .form, opens: .repo)
        ),
        PulseVariant(
            "Strip and Ways Out",
            idea: "Summary strip with every way out in the toolbar and the full-header Inspector",
            design: PulseDesign(sections: .summaryStrip, sidebar: .badged, toolbar: .waysOut, inspector: .header)
        ),
        PulseVariant(
            "List and Status",
            idea: "Inset List, the Now line in the toolbar, and a header Inspector on the running Attempt",
            design: PulseDesign(
                sections: .list, sidebar: .badged, toolbar: .status, inspector: .header, opens: .attempt
            )
        ),
        PulseVariant(
            "Disclosure Form",
            idea: "Collapsible groups, the toolbar's ways out, and a Get Info Inspector on the Feature",
            design: PulseDesign(sections: .disclosure, toolbar: .waysOut, inspector: .form, opens: .feature)
        ),
        // Round two: tinted cards throughout, the badged Sidebar, the header-and-form Inspector, and no
        // filter field. They differ in how the head colours and summarises the overall status.
        PulseVariant(
            "Strip and Cards",
            idea: "The summary strip over tinted cards; each figure jumps to its card; the Now line in the toolbar",
            design: PulseDesign(
                sections: .stripCards, sidebar: .badged, toolbar: .status, inspector: .headerForm, opens: .attempt
            )
        ),
        PulseVariant(
            "Status Band",
            idea: "A slim band tinted by the loudest state carries the name and status line over tinted cards",
            design: PulseDesign(sections: .bandCards, sidebar: .badged, toolbar: .minimal, inspector: .headerForm)
        ),
        PulseVariant(
            "Band and Strip",
            idea: "The slim status band carries the five figures on glass, over tinted cards; toolbar ways out",
            design: PulseDesign(
                sections: .bandStripCards, sidebar: .badged, toolbar: .waysOut, inspector: .headerForm,
                opens: .feature
            )
        ),
        PulseVariant(
            "Status Pill",
            idea: "A pill tinted by the loudest state beside the name, a tinted strip, and tinted cards",
            design: PulseDesign(
                sections: .pillCards, sidebar: .badged, toolbar: .status, inspector: .headerForm, opens: .repo
            )
        )
    ]
}

#Preview("Strip and Cards") {
    PulsePlayground(variant: "Strip and Cards", scenario: .nightRunning)
}

#Preview("Status Band") {
    PulsePlayground(variant: "Status Band")
}

#Preview("Band and Strip") {
    PulsePlayground(variant: "Band and Strip", scenario: .nightRunning)
}

#Preview("Status Pill") {
    PulsePlayground(variant: "Status Pill")
}
#endif
