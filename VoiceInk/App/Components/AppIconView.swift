import SwiftUI

struct AppIconView: View {
    var body: some View {
        // Light/dark renders of AppIcon.icon, so in-app copies follow the system appearance like the Dock icon.
        Image("appIconImage")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 120, height: 120)
    }
}
