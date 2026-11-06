import Foundation

/// Metadata shared by archive entries and filesystem rows. Keeping sorting
/// independent of the UI also lets the same rules apply to filtered results.
protocol BrowserSortableItem {
    var id: String { get }
    var name: String { get }
    var isDirectory: Bool { get }
    var size: UInt64? { get }
    var modified: Date? { get }
    var type: String { get }
}

struct BrowserSortComparator<Item: BrowserSortableItem>: SortComparator {
    enum Column: Hashable { case name, size, kind, modified }

    let column: Column
    var order: SortOrder = .forward

    init(_ column: Column, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    func compare(_ lhs: Item, _ rhs: Item) -> ComparisonResult {
        switch column {
        case .name: return directed(lhs.name.localizedStandardCompare(rhs.name))
        case .kind: return directed(lhs.type.localizedStandardCompare(rhs.type))
        case .size: return compareKnown(lhs.isDirectory ? nil : lhs.size, rhs.isDirectory ? nil : rhs.size)
        case .modified: return compareKnown(lhs.modified, rhs.modified)
        }
    }

    private func compareKnown<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult {
        switch (lhs, rhs) {
        // Unknown metadata is last in either direction; it isn't a zero-sized
        // file or a distant-past timestamp.
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (let lhs?, let rhs?):
            return directed(lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }

    private func directed(_ result: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

enum BrowserItemOrdering {
    static func sorted<Item: BrowserSortableItem>(_ items: [Item], using comparators: [BrowserSortComparator<Item>]) -> [Item] {
        items.sorted { lhs, rhs in
            // Keep folders together at the top as in the existing browser.
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            for comparator in comparators {
                let result = comparator.compare(lhs, rhs)
                if result != .orderedSame { return result == .orderedAscending }
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
