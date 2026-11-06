import SwiftUI

struct FoundationView: View {
    let name: String

    var body: some View {
        ContentUnavailableView {
            Label(name, systemImage: "music.note")
        } description: {
            Text("Server setup is not available in this build.")
        }
    }
}
