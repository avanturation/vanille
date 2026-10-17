import Foundation

final class StateStore {
    private let url: URL
    private let queue = DispatchQueue(label: "com.avanturation.Vanille.persistence", qos: .utility)
    private var pending: DispatchWorkItem?
    private(set) var loadWarning: String?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vanille/settings.json")
    }
    func load() -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
        do {
            var state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
            guard state.schema == 1 else { throw CocoaError(.coderReadCorrupt) }
            state.sanitize()
            return state
        } catch {
            loadWarning = "Saved settings could not be read. Defaults are in use."
            return SavedState()
        }
    }
    func save(_ state: SavedState, immediately: Bool = false) {
        pending?.cancel()
        let destination = url
        var durable = state
        if durable.timingSound { durable.processingPaused = true }
        durable.timingSound = false
        durable.sanitize()
        let snapshot = durable
        let item = DispatchWorkItem {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: [.atomic])
            } catch { NSLog("Vanille settings save failed: %@", error.localizedDescription) }
        }
        pending = item
        if immediately { queue.sync(execute: item) }
        else { queue.asyncAfter(deadline: .now() + 0.25, execute: item) }
    }
}
