extension Setup {
    /// Step 7: registers local notification permission once. Never throws — a refusal never fails setup.
    func reportNotifications() async {
        switch await registerNotifications() {
        case .allowed:
            output("Local notifications: allowed.")
        case .off(let reason):
            output(
                "Local notifications: off (\(reason)). Halted and closed Nights still reach you "
                    + "on the Night Card in Linear."
            )
        }
    }
}
