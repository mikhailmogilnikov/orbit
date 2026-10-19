import OrbitUI
import SwiftUI

struct GitSettingsPane: View {
    @Bindable var model: GitModel

    var body: some View {
        SettingsForm {
            Section("Editor") {
                Toggle(isOn: $model.showsChangeMarkers) {
                    Text("Change markers")
                    Text("Bars beside the line numbers for lines changed and not yet staged.")
                }
            }
            Section {
                Toggle(isOn: $model.showsBlame) {
                    Text("Blame for the current line")
                    Text("Who last changed the line with the caret, and when.")
                }
            } header: {
                Text("Status Bar")
            } footer: {
                Text("Blame for every line, beside the line numbers, is in Editor.")
            }
        }
    }
}
