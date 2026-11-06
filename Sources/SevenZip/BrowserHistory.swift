import Foundation

/// Navigation commits only after a destination has successfully loaded.
struct BrowserHistory<Location: Equatable> {
    private(set) var locations: [Location]
    private(set) var index = 0
    init(initial: Location) { locations = [initial] }
    mutating func replaceCurrent(_ location: Location) { locations[index] = location }
    var backIndex: Int? { index > 0 ? index - 1 : nil }
    var forwardIndex: Int? { index + 1 < locations.count ? index + 1 : nil }
    mutating func commit(_ location: Location, restoring restoredIndex: Int? = nil) {
        if let restoredIndex, locations.indices.contains(restoredIndex), locations[restoredIndex] == location {
            index = restoredIndex
            return
        }
        guard locations[index] != location else { return }
        locations.removeSubrange((index + 1)..<locations.count)
        locations.append(location)
        index = locations.count - 1
    }
}
