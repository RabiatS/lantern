import SwiftUI

/// Welcome until a model is on the phone, then the chat.
///
/// `--screen=<name>` on the command line opens one screen directly, for
/// screenshots: welcome, chat, personas, history, settings, transparency.
struct RootView: View {
    @Environment(AppState.self) private var app

    private var forced: String? { LaunchArguments.value(for: "screen") }

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
                    #if os(macOS)
                    MacChatView().transition(.opacity)
                    #else
                    ChatView().transition(.opacity)
                    #endif
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: app.showWelcome)
    }
}
