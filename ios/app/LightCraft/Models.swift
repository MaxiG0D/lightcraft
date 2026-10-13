import Foundation

// JSON shapes of the engine's command results (the same as the desktop app, CLI and MCP see).
// Only the fields the app reads are declared; new fields upstream are ignored.

/// A photo in the library grid / filmstrip (`catalog.query`).
struct LibraryPhoto: Decodable, Identifiable, Hashable, Sendable {
    let id: UInt64
    let fileName: String
    let format: String
    let rating: Int
    let flag: String
    let edited: Bool
}

struct CatalogPage: Decodable {
    let photos: [LibraryPhoto]
    let total: Int
}

/// `library.state`: undo / redo labels and the selection.
struct LibraryState: Decodable {
    struct Selection: Decodable {
        let active: UInt64?
        let ids: [UInt64]
    }
    let undo: String?
    let redo: String?
    let selection: Selection
    let visibleCount: Int
}

/// `presets.list`
struct PresetItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let group: String
    let favorite: Bool
    let builtin: Bool
}

/// `profiles.menu`
struct ProfilesMenu: Decodable {
    struct Profile: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let group: String
        let favorite: Bool
    }
    struct Group: Decodable, Identifiable {
        var id: String { name }
        let name: String
        let profiles: [Profile]
    }
    let favorites: [Profile]
    let groups: [Group]
}

/// `history.list`
struct HistoryList: Decodable {
    let history: [String]
    let cursor: Int?
}

/// The Edit panel's layout (`panelLayout()`, from `lightcraft-ffi` `panel.rs`, which mirrors the
/// desktop's `panels/edit.rs`).
struct PanelLayout: Decodable {
    struct Profile: Decodable { let amount: String }
    struct Mixer: Decodable {
        let bands: [String]
        let parts: [String]
        let bwPrefix: String
    }
    struct Grading: Decodable {
        let zones: [String]
        let parts: [String]
        let threeWay: [String]
        let shared: [String]
    }
    struct PointColor: Decodable {
        let parts: [String]
        let range: [String]
    }
    let profile: Profile
    let sections: [PanelSectionLayout]
    let mixer: Mixer
    let grading: Grading
    let pointColor: PointColor
    /// (label, `vignette.style` value)
    let vignetteStyles: [[String]]
    /// (key, title, icon)
    let gradingTabs: [[String]]

    static let shared: PanelLayout? = {
        guard let json = try? panelLayout(), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PanelLayout.self, from: data)
    }()
}

struct PanelSectionLayout: Decodable, Identifiable {
    let id: String
    let title: String
    let items: [LayoutItem]
}

/// One row of a section: a slider (`control`), a sub-title, a flyout, or a special editor.
struct LayoutItem: Decodable {
    let kind: String
    let id: String?
    let title: String?
    let icon: String?
    let items: [LayoutItem]?
    let enabledWhenNonZero: String?
    let control: String?
    let settings: String?
    let label: String?
    let controls: [String]?
    let parametric: [String]?
    let onlyWhenHdr: Bool?
}

/// Read-only access to the develop settings JSON (`PhotoState.settingsJson`) by dotted path.
struct SettingsJSON {
    private let root: [String: Any]

    init(_ json: String) {
        root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    func value(_ path: String) -> Any? {
        var node: Any? = root
        for key in path.split(separator: ".") {
            node = (node as? [String: Any])?[String(key)]
        }
        return node
    }

    func bool(_ path: String) -> Bool { value(path) as? Bool ?? false }
    func string(_ path: String) -> String? { value(path) as? String }
}

/// `{"a": {"b": value}}` for the path `a.b` (`develop.merge` settings).
func nestedJSON(_ path: String, _ value: Any) -> [String: Any] {
    var out: Any = value
    for key in path.split(separator: ".").reversed() {
        out = [String(key): out]
    }
    return out as? [String: Any] ?? [:]
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
