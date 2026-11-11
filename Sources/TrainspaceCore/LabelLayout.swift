import CoreGraphics
import Foundation

public enum LabelSlot: Int, CaseIterable, Sendable { case right, left, above, below }

public struct LabelRequest: Sendable {
    public var id: String
    public var anchor: CGPoint
    public var size: CGSize
    /// Lower is more important.
    public var priority: Double
    /// Clearance from the anchor to the label.
    public var gap: CGFloat

    public init(id: String, anchor: CGPoint, size: CGSize, priority: Double, gap: CGFloat = 7) {
        self.id = id
        self.anchor = anchor
        self.size = size
        self.priority = priority
        self.gap = gap
    }

    func rect(_ slot: LabelSlot) -> CGRect {
        switch slot {
        case .right: CGRect(x: anchor.x + gap, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .left: CGRect(x: anchor.x - gap - size.width, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .above: CGRect(x: anchor.x - size.width / 2, y: anchor.y - gap - size.height, width: size.width, height: size.height)
        case .below: CGRect(x: anchor.x - size.width / 2, y: anchor.y + gap, width: size.width, height: size.height)
        }
    }
}

public struct PlacedLabel: Sendable, Equatable {
    public var id: String
    public var rect: CGRect
    public var slot: LabelSlot
}

/// Greedy label placement: most important first, four candidate slots each, no overlaps with
/// other labels, other trains, or obstacles. Labels that don't fit are dropped.
///
/// Collision checks go through a uniform grid, so each candidate only tests the few rects near
/// it. That keeps a frame with several hundred labels linear rather than quadratic.
public enum LabelLayout {
    public static func layout(_ requests: [LabelRequest], obstacles: [CGRect], bounds: CGRect,
                              previous: [String: LabelSlot], glyphRadius: CGFloat = 4) -> [PlacedLabel] {
        let sorted = requests.sorted { $0.priority < $1.priority }
        // Glyphs are tagged with their request index so a label may touch its own train.
        var glyphs = SpatialGrid(cellSize: 64)
        for (i, r) in requests.enumerated() {
            glyphs.insert(CGRect(x: r.anchor.x - glyphRadius, y: r.anchor.y - glyphRadius,
                                 width: glyphRadius * 2, height: glyphRadius * 2), tag: i)
        }
        let index = Dictionary(requests.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var taken = SpatialGrid(cellSize: 64)
        for o in obstacles { taken.insert(o, tag: -1) }

        var placed: [PlacedLabel] = []
        placed.reserveCapacity(sorted.count)

        for req in sorted {
            let own = index[req.id] ?? -2
            var order = LabelSlot.allCases
            if let prev = previous[req.id], let i = order.firstIndex(of: prev) {
                order.remove(at: i)
                order.insert(prev, at: 0)
            }
            for slot in order {
                let r = req.rect(slot)
                guard bounds.contains(r),
                      !taken.intersects(r, ignoring: nil),
                      !glyphs.intersects(r, ignoring: own) else { continue }
                placed.append(PlacedLabel(id: req.id, rect: r, slot: slot))
                taken.insert(r, tag: -1)
                break
            }
        }
        return placed
    }
}

/// Buckets rects by grid cell. Large rects (obstacles like the info corner) span many cells,
/// which is fine: there are only a handful of them.
struct SpatialGrid {
    let cellSize: CGFloat
    private var cells: [Int: [(rect: CGRect, tag: Int)]] = [:]

    init(cellSize: CGFloat) { self.cellSize = cellSize }

    private func key(_ x: Int, _ y: Int) -> Int { (x &* 73_856_093) ^ (y &* 19_349_663) }

    private func range(_ r: CGRect) -> (ClosedRange<Int>, ClosedRange<Int>)? {
        guard r.minX.isFinite, r.minY.isFinite, r.maxX.isFinite, r.maxY.isFinite else { return nil }
        let x0 = Int((r.minX / cellSize).rounded(.down)), x1 = Int((r.maxX / cellSize).rounded(.down))
        let y0 = Int((r.minY / cellSize).rounded(.down)), y1 = Int((r.maxY / cellSize).rounded(.down))
        return (x0...max(x0, x1), y0...max(y0, y1))
    }

    mutating func insert(_ rect: CGRect, tag: Int) {
        guard let (xs, ys) = range(rect) else { return }
        for x in xs { for y in ys { cells[key(x, y), default: []].append((rect, tag)) } }
    }

    func intersects(_ rect: CGRect, ignoring tag: Int?) -> Bool {
        guard let (xs, ys) = range(rect) else { return false }
        for x in xs {
            for y in ys {
                guard let bucket = cells[key(x, y)] else { continue }
                for e in bucket where tag == nil || e.tag != tag {
                    if e.rect.intersects(rect) { return true }
                }
            }
        }
        return false
    }
}
