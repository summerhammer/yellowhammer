//
//  YellowhammerApp.swift
//  Yellowhammer
//
//  Created by Max Rozdobudko on 13.09.2026.
//

import Domain
import SwiftUI

/// The window app (Decision Gates Ruling, G-5). `AppLaunch` starts it for every launch that is not a
/// headless post.
///
/// Every window is scoped to one Project by its value; the Operator may open as many as they like,
/// one per Project, and `yellowhammer://project/<id>` opens the named one.
struct YellowhammerApp: App {
    var body: some Scene {
        WindowGroup(for: ProjectID.self) { $project in
            ProjectWindow(project: $project)
        }
    }
}
