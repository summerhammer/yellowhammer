extension ProjectConfigurationDecoder {
    /// The optional repository-relative `lockfile` path the Check record identifies (OQ198 item 3).
    func lockfile(in table: TOMLTable, path: String) throws(ConfigurationError) -> String? {
        guard let string = try decoding.optionalString("lockfile", in: table, path: path) else { return nil }
        let isAbsolute = string.hasPrefix("/") || string.hasPrefix("~")
        let hasParentComponent = string.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        let hasGlob = string.contains { "*?[".contains($0) }
        guard !isAbsolute, !hasParentComponent, !hasGlob else {
            throw decoding.error(line: table["lockfile"]?.line ?? table.line, key: "\(path).lockfile",
                                 .invalidLockfilePath(string))
        }
        return string
    }
}
