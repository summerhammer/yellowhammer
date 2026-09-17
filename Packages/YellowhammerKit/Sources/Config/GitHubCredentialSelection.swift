extension MachineConfiguration {
    /// The GitHub credential to use for a Project: its own override when present, otherwise the
    /// machine default. There is no per-repository credential.
    public func gitHubCredential(for project: ProjectConfiguration) -> CredentialReference {
        project.gitHubCredential ?? gitHubCredential
    }
}
