import SwiftUI

/// Shared tile metrics.
enum LinkTile {
    static let radius: CGFloat = 10
    static let minHeight: CGFloat = 86
}

/// Colours and labels for folder choices. Colour names come from `LinkFolder.colorNames`.
enum LinkPalette {
    static func color(_ name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "gray": .gray
        default: .blue
        }
    }

    static func label(forColor name: String) -> String {
        name.capitalized
    }

    static func label(forSymbol symbol: String) -> String {
        symbolLabels[symbol] ?? symbol
    }

    private static let symbolLabels: [String: String] = [
        "folder": "Folder",
        "star": "Favorites",
        "briefcase": "Work",
        "book": "Reading",
        "hammer": "Tools",
        "globe": "Web",
        "play.rectangle": "Videos",
        "cart": "Shopping",
        "graduationcap": "Learning",
        "person.2": "People",
    ]
}

/// "1 link" / "3 links".
enum LinkCount {
    static func text(_ count: Int) -> String {
        count == 1 ? "1 link" : "\(count) links"
    }
}

/// Text shared by the link fields.
enum LinkCopy {
    static let notALink = "That doesn’t look like a link."
}
