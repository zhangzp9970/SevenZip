import Foundation

private struct Row: BrowserSortableItem {
    let id: String
    let name: String
    var isDirectory = false
    var size: UInt64? = nil
    var modified: Date? = nil
    var type = "TXT file"
}

@main
struct BrowserSortingSmoke {
    static func main() {
        let rows = [
            Row(id: "10", name: "file10.txt", size: 2, modified: Date(timeIntervalSince1970: 30)),
            Row(id: "2", name: "file2.txt", size: 30, modified: Date(timeIntervalSince1970: 20)),
            Row(id: "1", name: "file1.txt", size: 30, modified: Date(timeIntervalSince1970: 10)),
            Row(id: "unknown", name: "unknown.txt"),
            Row(id: "huge", name: "huge.zip", size: UInt64.max, modified: Date(timeIntervalSince1970: -1), type: "ZIP file"),
            Row(id: "dir10", name: "folder10", isDirectory: true, type: "Folder"),
            Row(id: "dir2", name: "folder2", isDirectory: true, type: "Folder")
        ]
        typealias Comparator = BrowserSortComparator<Row>
        func ids(_ column: Comparator.Column, _ order: SortOrder = .forward, items: [Row]? = nil) -> [String] {
            BrowserItemOrdering.sorted(items ?? rows, using: [Comparator(column, order: order)]).map(\.id)
        }
        precondition(ids(.name) == ["dir2", "dir10", "1", "2", "10", "huge", "unknown"])
        precondition(ids(.name, .reverse) == ["dir10", "dir2", "unknown", "huge", "10", "2", "1"])
        // Equal sizes use natural names; full UInt64 range and missing sizes
        // retain their meaning rather than sorting formatted display strings.
        precondition(ids(.size) == ["dir2", "dir10", "10", "1", "2", "huge", "unknown"])
        precondition(ids(.size, .reverse) == ["dir2", "dir10", "huge", "1", "2", "10", "unknown"])
        precondition(ids(.modified) == ["dir2", "dir10", "huge", "1", "2", "10", "unknown"])
        precondition(ids(.modified, .reverse) == ["dir2", "dir10", "10", "2", "1", "huge", "unknown"])
        precondition(ids(.kind) == ["dir2", "dir10", "1", "2", "10", "unknown", "huge"])
        precondition(ids(.kind, .reverse) == ["dir2", "dir10", "huge", "1", "2", "10", "unknown"])
        let filtered = rows.filter { $0.name.localizedCaseInsensitiveContains("FILE") }
        precondition(ids(.size, .reverse, items: filtered) == ["1", "2", "10"])
        let secondary = BrowserItemOrdering.sorted(rows, using: [Comparator(.size, order: .reverse), Comparator(.modified, order: .reverse)])
        precondition(secondary.map(\.id) == ["dir2", "dir10", "huge", "2", "1", "10", "unknown"])
        let equalNames = [Row(id: "b", name: "same.txt", size: 1), Row(id: "a", name: "same.txt", size: 1)]
        precondition(ids(.name, items: equalNames) == ["a", "b"])
        precondition(ids(.name, items: equalNames.reversed()) == ["a", "b"])
        var toggled = Comparator(.name)
        toggled.order = .reverse
        precondition(BrowserItemOrdering.sorted(filtered, using: [toggled]).map(\.id) == ["10", "2", "1"])
        print("PASS: natural names, folders first, numeric sizes, dates, kinds, ascending/descending, missing metadata, filtered results and stable ties")
    }
}
