/// The SF Symbols that stand for Yellowhammer's objects, named once so an object looks the same on every
/// screen. Change one here and every view that draws it follows.
enum DomainSymbol {
    /// A Repo: the Overview's Sidebar and Pulse, the Inspector, and the Add Project sheet's Repo cards.
    static let repo = "shippingbox"
    /// The filled form of ``repo``, for a heading. Every symbol chosen for ``repo`` must have a `.fill` form.
    static let repoFill = "\(repo).fill"
    /// An Board Connection, the connected workspace of a board vendor: the Settings window's Boards cards.
    static let appInstallation = "building.2"
    /// A Code Hosting Connection: the Settings window's Code Hosting cards.
    static let codeHostingConnection = "link"
}
