import SwiftUI

struct GitSettingsPane: View {
    @Bindable var model: GitModel

    var body: some View {
        Form {
            Section("Editor") {
                Toggle(isOn: $model.showsChangeMarkers) {
                    Text("Change markers in the gutter")
                    Text("Bars next to line numbers for lines changed and not yet staged.")
                }
                Toggle(isOn: $model.showsBlame) {
                    Text("Blame in the status bar")
                    Text("Who last changed the line with the caret, and when.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
