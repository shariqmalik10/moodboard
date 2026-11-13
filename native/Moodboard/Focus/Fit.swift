import Foundation

/// Sizes shared by the two places a component stands on its own: the focus view and the list view.
enum Stand {
  /// The dials panel down the right side.
  static let inspectorWidth = 360.0

  /// The widest a component or material is shown: 1.6 times a component's real size, or a material's own width.
  static func naturalWidth(of item: Item) -> Double {
    switch item.body {
    case .component(_, let crop): crop.w * 1.6
    case .material(let material): max(material.w, Grain.cardWidth)
    }
  }

  /// The widest an item can stand inside this much room, keeping its shape.
  static func width(of item: Item, inWidth width: Double, height: Double) -> Double {
    min(width, height / item.aspect, naturalWidth(of: item))
  }
}
