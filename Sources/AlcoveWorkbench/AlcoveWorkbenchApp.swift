import SwiftUI

@main
struct AlcoveWorkbenchApp: App {
    init() {
        let arguments = CommandLine.arguments
        if WorkbenchCLI.handles(arguments) {
            exit(WorkbenchCLI.run(arguments))
        }
    }

    var body: some Scene {
        WindowGroup("Alcove 激活器") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 660)
    }
}
