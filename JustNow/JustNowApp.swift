//
//  JustNowApp.swift
//  JustNow
//

import SwiftUI

@main
struct JustNowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
