import SwiftUI

struct AppIconView: View {
    var body: some View {
        if let image = NSImage(named: "AppIcon") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
        }
    }
}
