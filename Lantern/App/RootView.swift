import SwiftUI

/// Welcome until a model is on the phone, then the chat.
///
/// `--screen <name>` on the command line opens one screen directly, for
/// screenshots in the simulator: welcome, chat, personas, history, settings,
/// transparency.
struct RootView: View {
    @Environment(AppState.self) private var app

    private var forced: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--screen"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    var body: some View {
        Group {
            switch forced {
            case "welcome": WelcomeView()
            case "personas": PersonaSheet()
            case "history": HistorySheet()
            case "settings": SettingsView()
            case "transparency": NavigationStack { TransparencyView() }.background(Theme.background)
            default:
                if app.showWelcome {
                    WelcomeView().transition(.opacity)
                } else {
                    ChatView().transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.showWelcome)
    }
}
