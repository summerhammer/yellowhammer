import SwiftUI

/// A Repo's Repo Role, chosen from `roles`. An empty role is "Choose…". A role that is not in `roles`, such as one
/// a hand-edited file names, stays selectable so the picker never holds a selection none of its tags match.
struct RepoRoleChoice: View {
    @Binding var role: String
    let roles: [String]
    var identifier: String

    var body: some View {
        Picker("Repo Role", selection: $role) {
            Text("Choose\u{2026}").tag("")
            ForEach(roles, id: \.self) { Text($0).tag($0) }
            if !role.isEmpty, !roles.contains(role) {
                Text(role).tag(role)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier(identifier)
    }
}
