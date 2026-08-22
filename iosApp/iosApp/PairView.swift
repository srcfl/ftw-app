import SwiftUI

struct PairView: View {
    @EnvironmentObject var model: AppModel
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("FTW")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color(red: 0.91, green: 0.91, blue: 0.91))
            Text("Scan the pairing code on your box.")
                .font(.body)
                .foregroundStyle(Color(red: 0.63, green: 0.63, blue: 0.63))
                .multilineTextAlignment(.center)
            if scanning {
                QRScanner { code in
                    scanning = false
                    model.applyScanned(code)
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Button {
                    scanning = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color(red: 0.16, green: 0.16, blue: 0.16), lineWidth: 1)
                            .frame(height: 240)
                        VStack(spacing: 8) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 48))
                                .foregroundStyle(Color(red: 0.85, green: 0.82, blue: 0.25))
                            Text("Scan")
                                .font(.footnote)
                                .foregroundStyle(Color(red: 0.52, green: 0.52, blue: 0.52))
                        }
                    }
                }
            }
            TextField("Or paste a pairing link", text: $model.paste)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(red: 0.09, green: 0.09, blue: 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(Color(red: 0.91, green: 0.91, blue: 0.91))
            Button("Continue", action: model.pair)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.85, green: 0.82, blue: 0.25))
                .foregroundStyle(Color(red: 0.04, green: 0.04, blue: 0.04))
            if let help = model.help {
                Text(help)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.72, green: 0.18, blue: 0.12))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.05, blue: 0.05))
    }
}
