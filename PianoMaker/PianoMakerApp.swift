//
//  PianoMakerApp.swift
//  PianoMaker
//
//  Created by Rani Yaqoob on 2025-08-12.
//

import SwiftUI
import AVFoundation

@main
struct PianoMakerApp: App {
    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    Task {
                        await Config.discoverAndSetServerBaseURL()
                    }
                    #if DEBUG
                    if let url = Bundle.main.url(forResource: "SalC5Light2", withExtension: "sf2", subdirectory: "Resources/SoundFonts")
                        ?? Bundle.main.url(forResource: "FluidR3_GM", withExtension: "sf2", subdirectory: "Resources/SoundFonts") {
                        print("Bundled SF2 detected:", url.path)
                    } else {
                        print("No SF2 detected in bundle; using default GM")
                    }
                    print("If you want ML performer, run: docker run --rm -p 8502:8502 ghcr.io/ai-perf/magenta-performer:latest")
                    #endif
                }
        }
    }
}
