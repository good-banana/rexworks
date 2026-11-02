import Foundation
import MDViewerLayout

public struct BlockIdentity: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case details, code, table, link
  }

  public var kind: Kind
  public var text: String
  public var ordinal: Int

  public init(kind: Kind, text: String, ordinal: Int) {
    self.kind = kind
    self.text = text
    self.ordinal = ordinal
  }

  static func numbered(_ items: [(BlockID, Kind, String)]) -> [BlockID: BlockIdentity] {
    var seen: [String: Int] = [:]
    var result: [BlockID: BlockIdentity] = [:]
    for (id, kind, text) in items.sorted(by: { $0.0 < $1.0 }) {
      let key = "\(kind)\u{0}\(text)"
      let ordinal = seen[key, default: 0]
      seen[key] = ordinal + 1
      result[id] = BlockIdentity(kind: kind, text: text, ordinal: ordinal)
    }
    return result
  }

  static func details(in prepared: PreparedDocument) -> [BlockID: BlockIdentity] {
    var firstUnit: [BlockID: Range<Int>] = [:]
    for unit in prepared.units where firstUnit[unit.block] == nil { firstUnit[unit.block] = unit.range }
    return numbered(
      prepared.detailsBlocks.map { id in
        (id, .details, firstUnit[id].map { prepared.text.substring(with: NSRange($0)) } ?? "")
      })
  }

  static func regions(in page: PageLayout) -> [BlockID: BlockIdentity] {
    var spans: [BlockID: Range<Int>] = [:]
    for fragment in page.fragments {
      guard let region = fragment.region else { continue }
      let span = spans[region] ?? fragment.range
      spans[region] = min(span.lowerBound, fragment.range.lowerBound)..<max(span.upperBound, fragment.range.upperBound)
    }
    var items: [(BlockID, Kind, String)] = []
    for region in page.regions {
      switch region.kind {
      case .codeBlock:
        items.append((region.id, .code, page.prepared.codeBlocks[region.id]?.code ?? ""))
      case .table:
        items.append((region.id, .table, spans[region.id].map { page.plainText($0) } ?? ""))
      }
    }
    var code = numbered(items.filter { $0.1 == .code })
    code.merge(numbered(items.filter { $0.1 == .table })) { first, _ in first }
    return code
  }

  static func links(in page: PageLayout) -> [Range<Int>: BlockIdentity] {
    var seen: [String: Int] = [:]
    var result: [Range<Int>: BlockIdentity] = [:]
    for link in page.prepared.links {
      let text = link.href + "\u{0}" + page.prepared.text.substring(with: NSRange(link.range))
      let ordinal = seen[text, default: 0]
      seen[text] = ordinal + 1
      result[link.range] = BlockIdentity(kind: .link, text: text, ordinal: ordinal)
    }
    return result
  }
}

public struct CarriedDetails: Equatable, Sendable {
  public var expanded: Set<BlockIdentity>
  public var known: Set<BlockIdentity>

  public init(expanded: Set<BlockIdentity>, known: Set<BlockIdentity>) {
    self.expanded = expanded
    self.known = known
  }

  public func resolve(_ prepared: PreparedDocument) -> Set<BlockID> {
    var result: Set<BlockID> = []
    for (id, identity) in BlockIdentity.details(in: prepared) {
      if expanded.contains(identity) {
        result.insert(id)
      } else if !known.contains(identity), prepared.initiallyExpandedDetails.contains(id) {
        result.insert(id)
      }
    }
    return result
  }
}
