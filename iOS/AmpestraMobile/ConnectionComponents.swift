import SwiftUI

struct ConnectionIntroCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AmpestraMark(size: 54)

            VStack(alignment: .leading, spacing: 6) {
                Text("Find your KEF speaker")
                    .font(.title2.weight(.bold))
                Text("Your iPhone and speaker need to be connected to the same Wi‑Fi network.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .ampestraCard()
    }
}

struct ConnectionPrivacyNote: View {
    var body: some View {
        Label(
            "Ampestra communicates directly with your speaker on your network.",
            systemImage: "lock.shield.fill"
        )
        .font(.caption)
        .foregroundStyle(AmpestraTheme.mutedText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
