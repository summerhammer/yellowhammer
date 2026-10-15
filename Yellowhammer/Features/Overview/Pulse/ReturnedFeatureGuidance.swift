import SwiftUI

/// Explains the Operator's choices and why a returned Feature can still appear after they act.
struct ReturnedFeatureGuidance: View {
    var body: some View {
        Text("""
        Merge the Feature's pull requests on GitHub, or set the Feature Card in Linear to Kept in Flight \
        (when offered) or Abandoned. Yellowhammer reads and records your choice at the next author Act. \
        If you've already acted, the Feature can remain returned until then.
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
