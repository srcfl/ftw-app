import SwiftUI

struct NowView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.site?.label ?? "Home")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.91, green: 0.91, blue: 0.91))
                Spacer()
                Text("via \(model.carrier) · \(model.srcState)")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.52, green: 0.52, blue: 0.52))
            }
            Text(model.headline)
                .font(.title3)
                .foregroundStyle(Color(red: 0.91, green: 0.91, blue: 0.91))
            VStack(alignment: .leading, spacing: 8) {
                row("Grid", model.grid)
                row("Solar", model.pv)
                row("Battery", model.battery)
                row("House", model.load)
            }
            Spacer()
            Button("Forget this home", action: model.forget)
                .foregroundStyle(Color(red: 0.63, green: 0.63, blue: 0.63))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.05, green: 0.05, blue: 0.05))
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Color(red: 0.63, green: 0.63, blue: 0.63))
            Spacer()
            Text(value).foregroundStyle(Color(red: 0.91, green: 0.91, blue: 0.91))
        }
    }
}
