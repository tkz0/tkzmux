// ComponentSnapshot — renders any TkzApp component to an sRGB PNG plus a `LayoutDump`, headlessly,
// at any scale (WOR-307 S1). The Mac half of ADR-0003's L0 and L5 layers: the goldens that the
// M3 refactors must keep byte-identical, and that the Linux canvas views are measured against.
//
// Why it is not just `layer.render(in:)` or `cacheDisplay(in:to:)`, the two patterns it
// generalises (`SidebarRowViewTests`, `StatusBarViewTests`, which keep their own helpers):
//
//   * `cacheDisplay` runs every view's `draw(_:)` but drops custom sublayers: the sidebar's dots,
//     badges and colour edges vanish from the bitmap.
//   * `layer.render(in:)` draws a layer tree, but without a window a view's `draw(_:)` content is
//     not in it, and neither are its subviews: a subview's backing layer is only grafted into its
//     superview's layer once the hierarchy reaches a window (`StatusDotView.swift` header). So
//     `NSTextField` labels and `StatusBarView`'s text are missing.
//
// So the harness walks the *view* tree itself, in drawing order, and for each view draws what
// Core Animation would: its own layer (background, then contents, then its own sublayers, then
// the border) through `render(in:)`, with `draw(_:)` as the contents, and then its subviews. No
// window is involved, so nothing depends on the screen the tests happen to run on: every glyph is
// rasterised directly at the requested scale.
//
// Determinism, which the goldens depend on:
//
//   * the appearance is forced from the theme (`darkAqua` for the dark presets, `aqua` for Light),
//     both on the view and as the current drawing appearance while it is built and drawn;
//   * the layers' `contentsScale` comes from `LayerContentsScale` (the one production seam, set
//     for the duration of the render) and is applied to the whole tree;
//   * animations are frozen: every attached `CAAnimation` is recorded in the dump, then removed,
//     and the whole build-layout-draw runs inside `CATransaction.setDisableActions(true)`;
//   * the bundled fonts are registered first, so a mono run is JetBrains Mono whichever tests ran
//     earlier in the process (otherwise it depends on test order whether it falls back to Menlo);
//   * the PNG is written by TkzPNG, whose output depends only on the pixels.
//
// At a fractional scale the bitmap is `ceil(logical × scale)` pixels on an axis whose product is
// not whole (a 44 pt row is 71 px at 1.6); the dump records that, and the component is drawn from
// the top-left corner so only the last row or column is partial.
//
// What cannot be rendered deterministically (vibrancy, `NSSearchField`, a `.regular` table
// selection, overlay scrollers) is drawn as it comes out and listed in the dump's `masks`, for the
// comparison to leave out (ADR-0003 section 3).
//
// Run: `swift test --filter ComponentSnapshot`. With `TKZMUX_TEST_ARTIFACTS=<dir>` set, each
// render is also written to `<dir>/component-snapshots/<id>@<preset>@<scale>.{png,json}`.

import AppKit
import TkzCore
import TkzPNG
import TkzTerminalRender

@testable import TkzApp

@MainActor
enum ComponentSnapshot {
    /// Something that can be snapshotted: an id, and how to build it from a fixture model.
    struct Component<Model> {
        /// Stable, dotted, e.g. `sidebar.sessionRow`. Names the golden files.
        let id: String
        /// Builds and configures the view. It is then sized to the requested size and laid out.
        let make: @MainActor (Model, Theme, CGSize) -> NSView
        /// Painted under the view, for components that are transparent where the app shows the
        /// surface they sit on (a sidebar row over `sidebarBackground`). `nil` leaves it clear.
        var backdrop: (@MainActor (Theme) -> RGB)? = nil
        /// Results the frame tree cannot show (a wrap decision), evaluated after layout.
        var facts: (@MainActor (Model, NSView) -> [String: String])? = nil
    }

    enum Failure: Error, CustomStringConvertible {
        case noAppearance(String)
        case bitmap(width: Int, height: Int)
        case notRendered

        var description: String {
            switch self {
            case .noAppearance(let name): "no NSAppearance named \(name)"
            case .bitmap(let width, let height): "could not make a \(width)×\(height) sRGB bitmap"
            case .notRendered: "the render did not run"
            }
        }
    }

    /// The scales every component is captured at: the Mac's backing scale and Hyprland's 1.6.
    nonisolated static let scales: [Double] = [2.0, 1.6]

    /// Renders `model` through `component` at `size` (logical points), themed and at `scale`.
    static func render<Model>(
        id component: Component<Model>, model: Model, size: CGSize, theme: Theme, scale: Double
    ) throws -> (png: Data, layout: LayoutDump) {
        _ = NSApplication.shared
        _ = FontSet.registration
        let name: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: name) else { throw Failure.noAppearance(name.rawValue) }

        var result: Result<(png: Data, layout: LayoutDump), any Error> = .failure(Failure.notRendered)
        appearance.performAsCurrentDrawingAppearance {
            result = Result {
                try LayerContentsScale.withScale(CGFloat(scale)) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    defer { CATransaction.commit() }
                    return try renderNow(
                        component, model: model, size: size, theme: theme, scale: scale,
                        appearance: appearance)
                }
            }
        }
        return try result.get()
    }

    /// The size Auto Layout gives the component on its own, for components sized by their content.
    static func fittingSize<Model>(of component: Component<Model>, model: Model, theme: Theme) -> CGSize {
        let view = component.make(model, theme, .zero)
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    /// Writes the PNG and the JSON into `$TKZMUX_TEST_ARTIFACTS/component-snapshots/` when that is
    /// set, for looking at by hand; does nothing otherwise.
    static func writeArtifacts(_ snapshot: (png: Data, layout: LayoutDump)) throws {
        guard let dir = ProcessInfo.processInfo.environment["TKZMUX_TEST_ARTIFACTS"] else { return }
        let folder = URL(fileURLWithPath: dir).appendingPathComponent("component-snapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = fileStem(snapshot.layout)
        try snapshot.png.write(to: folder.appendingPathComponent(base + ".png"))
        try snapshot.layout.jsonData().write(to: folder.appendingPathComponent(base + ".json"))
    }

    /// `sidebar.sessionRow@midnightIndigo@1.6`: the file name, without extension, of a snapshot.
    static func fileStem(_ layout: LayoutDump) -> String {
        "\(layout.component)@\(layout.theme)@\(layout.scale)"
    }

    // MARK: - Rendering

    private static func renderNow<Model>(
        _ component: Component<Model>, model: Model, size: CGSize, theme: Theme, scale: Double,
        appearance: NSAppearance
    ) throws -> (png: Data, layout: LayoutDump) {
        let view = component.make(model, theme, size)
        view.appearance = appearance
        view.setFrameOrigin(.zero)
        view.setFrameSize(size)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        applyContentsScale(CGFloat(scale), to: view)

        var walker = Walker(root: view)
        let tree = walker.node(for: view)
        let width = LayoutDump.PixelExtent(logical: Double(size.width), scale: scale)
        let height = LayoutDump.PixelExtent(logical: Double(size.height), scale: scale)
        let layout = LayoutDump(
            component: component.id,
            theme: theme.preset.rawValue,
            appearance: appearance.name.rawValue,
            scale: scale,
            size: .init(width: Double(size.width), height: Double(size.height)),
            pixels: .init(width: width, height: height),
            facts: component.facts?(model, view) ?? [:],
            masks: walker.masks,
            root: tree)

        let bytesPerRow = width.pixels * 4
        guard width.pixels > 0, height.pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width.pixels, height: height.pixels, bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw Failure.bitmap(width: width.pixels, height: height.pixels) }
        ctx.clear(CGRect(x: 0, y: 0, width: width.pixels, height: height.pixels))
        // Top-aligned: the partial row of a fractional height is the bottom one, as on a top-left
        // canvas. At a whole-pixel height this is a translation by zero.
        ctx.translateBy(x: 0, y: CGFloat(height.pixels) - size.height * CGFloat(scale))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        if let backdrop = component.backdrop?(theme) {
            ctx.setFillColor(backdrop.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        walker.render(view, in: ctx)

        guard let data = ctx.data else { throw Failure.bitmap(width: width.pixels, height: height.pixels) }
        let premultiplied = [UInt8](UnsafeRawBufferPointer(start: data, count: bytesPerRow * height.pixels))
        let png = try PNG.encode(
            straightAlpha(premultiplied), width: width.pixels, height: height.pixels, colorType: .rgba)
        return (Data(png), layout)
    }

    /// The layers' scale for this capture, on every layer in the tree. Subviews are walked
    /// separately because without a window their layers are not sublayers of their superview's.
    private static func applyContentsScale(_ scale: CGFloat, to view: NSView) {
        if let layer = view.layer { SidebarLayers.applyContentsScale(scale, to: layer) }
        for subview in view.subviews { applyContentsScale(scale, to: subview) }
    }

    /// Premultiplied RGBA (what the bitmap context holds) to straight RGBA (what PNG stores),
    /// rounding to nearest. Exact for every opaque pixel.
    static func straightAlpha(_ premultiplied: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: premultiplied.count)
        var index = 0
        while index + 3 < premultiplied.count {
            let alpha = Int(premultiplied[index + 3])
            if alpha == 255 {
                out[index] = premultiplied[index]
                out[index + 1] = premultiplied[index + 1]
                out[index + 2] = premultiplied[index + 2]
            } else if alpha > 0 {
                for channel in 0..<3 {
                    let value = (Int(premultiplied[index + channel]) * 255 + alpha / 2) / alpha
                    out[index + channel] = UInt8(min(255, value))
                }
            }
            out[index + 3] = UInt8(alpha)
            index += 4
        }
        return out
    }
}

// MARK: - The view-tree walker

/// Builds the dump and draws the tree. Coordinates: the context arrives in the component's
/// logical space with a y-up origin at its bottom-left corner; `transform(of:)` maps any view's own
/// coordinates (flipped or not) into it.
@MainActor
private struct Walker {
    let root: NSView
    private(set) var masks: [LayoutDump.Mask] = []

    init(root: NSView) {
        self.root = root
    }

    // MARK: Geometry

    /// `point`, in `view`'s coordinates, in the root's y-up space.
    private func upPoint(_ point: CGPoint, in view: NSView) -> CGPoint {
        let converted = view === root ? point : view.convert(point, to: root)
        return root.isFlipped ? CGPoint(x: converted.x, y: root.bounds.height - converted.y) : converted
    }

    /// The affine map from `view`'s coordinates to the root's y-up space.
    private func transform(of view: NSView) -> CGAffineTransform {
        let origin = upPoint(.zero, in: view)
        let unitX = upPoint(CGPoint(x: 1, y: 0), in: view)
        let unitY = upPoint(CGPoint(x: 0, y: 1), in: view)
        return CGAffineTransform(
            a: unitX.x - origin.x, b: unitX.y - origin.y,
            c: unitY.x - origin.x, d: unitY.y - origin.y,
            tx: origin.x, ty: origin.y)
    }

    /// `rect`, in `view`'s coordinates, as a top-left rect in the root.
    private func topLeft(_ rect: CGRect, in view: NSView) -> LayoutDump.Rect {
        let converted = view === root ? rect : view.convert(rect, to: root)
        let y = root.isFlipped ? converted.minY : root.bounds.height - converted.maxY
        return LayoutDump.Rect(
            x: Double(converted.minX), y: Double(y),
            width: Double(converted.width), height: Double(converted.height))
    }

    /// `rect`, in `layer`'s bounds space, in `ancestor`'s sublayer space, composed from each
    /// layer's position, anchor point and transform. Not `convert(_:to:)`, which also applies a
    /// view layer's `isGeometryFlipped`: a view's sublayers are positioned in the view's own
    /// coordinates, flipped or not, and that is the space this returns.
    private static func rect(_ rect: CGRect, of layer: CALayer, in ancestor: CALayer) -> CGRect {
        var result = rect
        var current = layer
        while current !== ancestor, let parent = current.superlayer {
            result = result.applying(toSuperlayer(current))
            current = parent
        }
        return result
    }

    private static func toSuperlayer(_ layer: CALayer) -> CGAffineTransform {
        let bounds = layer.bounds
        let anchor = CGPoint(
            x: bounds.minX + layer.anchorPoint.x * bounds.width,
            y: bounds.minY + layer.anchorPoint.y * bounds.height)
        let transform = CATransform3DIsAffine(layer.transform)
            ? CATransform3DGetAffineTransform(layer.transform) : .identity
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(transform)
            .concatenating(CGAffineTransform(translationX: layer.position.x, y: layer.position.y))
    }

    /// The layers of `view`'s subviews: drawn when their own view is, never as part of `view`'s.
    private static func subviewLayers(of view: NSView) -> Set<ObjectIdentifier> {
        Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
    }

    /// `true` when the view's class (AppKit's own controls included) overrides `draw(_:)`.
    private static func drawsContent(_ view: NSView) -> Bool {
        let selector = #selector(NSView.draw(_:))
        return class_getInstanceMethod(type(of: view), selector)
            != class_getInstanceMethod(NSView.self, selector)
    }

    private static func typeName(_ object: AnyObject) -> String {
        String(describing: type(of: object))
    }

    // MARK: Dump

    /// The node for `view` and everything under it. Records the masks, and freezes (records,
    /// then removes) every animation it finds.
    mutating func node(for view: NSView) -> LayoutDump.Node {
        recordMasks(view)
        var children: [LayoutDump.Node] = []
        if !view.isHidden {
            if let layer = view.layer {
                let skip = Self.subviewLayers(of: view)
                for sublayer in layer.sublayers ?? [] where !skip.contains(ObjectIdentifier(sublayer)) {
                    children.append(node(for: sublayer, in: view, viewLayer: layer))
                }
            }
            for subview in view.subviews {
                children.append(node(for: subview))
            }
        }
        return LayoutDump.Node(
            kind: .view,
            type: Self.typeName(view),
            name: view.identifier?.rawValue,
            frame: topLeft(view.bounds, in: view),
            hidden: view.isHidden ? true : nil,
            alpha: view.alphaValue < 1 ? Double(view.alphaValue) : nil,
            flipped: view.isFlipped ? true : nil,
            animations: Self.freeze(view.layer),
            text: (view as? NSTextField).map(Self.textRun),
            children: children.isEmpty ? nil : children)
    }

    private func node(for layer: CALayer, in view: NSView, viewLayer: CALayer) -> LayoutDump.Node {
        let children = (layer.sublayers ?? []).map { node(for: $0, in: view, viewLayer: viewLayer) }
        return LayoutDump.Node(
            kind: .layer,
            type: Self.typeName(layer),
            name: layer.name,
            frame: topLeft(Self.rect(layer.bounds, of: layer, in: viewLayer), in: view),
            hidden: layer.isHidden ? true : nil,
            alpha: layer.opacity < 1 ? Double(layer.opacity) : nil,
            animations: Self.freeze(layer),
            text: (layer as? CATextLayer).flatMap(Self.textRun),
            children: children.isEmpty ? nil : children)
    }

    private static func freeze(_ layer: CALayer?) -> [String]? {
        guard let layer, let keys = layer.animationKeys(), !keys.isEmpty else { return nil }
        layer.removeAllAnimations()
        return keys.sorted()
    }

    private mutating func recordMasks(_ view: NSView) {
        guard !view.isHidden else { return }
        let source = Self.typeName(view)
        switch view {
        case is NSVisualEffectView:
            masks.append(.init(kind: .vibrancy, frame: topLeft(view.bounds, in: view), source: source))
        case is NSSearchField:
            masks.append(.init(kind: .searchField, frame: topLeft(view.bounds, in: view), source: source))
        case is NSScroller:
            masks.append(.init(kind: .scroller, frame: topLeft(view.bounds, in: view), source: source))
        case let table as NSTableView where table.selectionHighlightStyle == .regular:
            for row in table.selectedRowIndexes {
                masks.append(.init(
                    kind: .accentSelection, frame: topLeft(table.rect(ofRow: row), in: table), source: source))
            }
        default:
            break
        }
    }

    // MARK: Text runs

    private static func textRun(_ layer: CATextLayer) -> LayoutDump.TextRun? {
        let attributed: NSAttributedString
        if let string = layer.string as? NSAttributedString {
            attributed = string
        } else if let string = layer.string as? String {
            attributed = NSAttributedString(string: string, attributes: [.font: Self.font(of: layer)])
        } else {
            return nil
        }
        let font = attributed.length > 0
            ? (attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? Self.font(of: layer)
            : Self.font(of: layer)
        let available = layer.bounds.width
        let measured = attributed.size().width
        var fittingHeight: Double?
        let truncated: Bool
        if layer.isWrapped {
            let fitting = attributed.boundingRect(
                with: CGSize(width: available, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            fittingHeight = Double(fitting)
            truncated = fitting > layer.bounds.height
        } else {
            truncated = layer.truncationMode != .none && measured > available
        }
        return LayoutDump.TextRun(
            string: attributed.string, font: font.fontName, size: Double(font.pointSize),
            measuredWidth: Double(measured), availableWidth: Double(available),
            wraps: layer.isWrapped, fittingHeight: fittingHeight, truncated: truncated)
    }

    /// The font a `CATextLayer` draws a plain string in: `font` names the face, `fontSize` the size.
    private static func font(of layer: CATextLayer) -> NSFont {
        let size = layer.fontSize
        if let font = layer.font as? NSFont {
            return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }
        if let name = layer.font as? String, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }

    private static func textRun(_ field: NSTextField) -> LayoutDump.TextRun {
        let attributed = field.attributedStringValue
        let font = field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let available = field.cell?.titleRect(forBounds: field.bounds).width ?? field.bounds.width
        let measured = attributed.size().width
        let wraps = (field.cell?.wraps ?? false) && field.maximumNumberOfLines != 1
        var fittingHeight: Double?
        let truncated: Bool
        if wraps {
            let fitting = field.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: field.bounds.width, height: .greatestFiniteMagnitude)).height
                ?? field.bounds.height
            fittingHeight = Double(fitting)
            truncated = fitting > field.bounds.height
        } else {
            truncated = measured > available
        }
        return LayoutDump.TextRun(
            string: attributed.string, font: font.fontName, size: Double(font.pointSize),
            measuredWidth: Double(measured), availableWidth: Double(available),
            wraps: wraps, fittingHeight: fittingHeight, truncated: truncated)
    }

    // MARK: Drawing

    /// Draws `view` and its subviews into `ctx`, whose current transform is the root's y-up space.
    func render(_ view: NSView, in ctx: CGContext) {
        guard !view.isHidden, view.alphaValue > 0 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // A view's alpha applies to it and its subviews as a group, as on screen.
        let grouped = view.alphaValue < 1
        if grouped {
            ctx.setAlpha(view.alphaValue)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if grouped { ctx.endTransparencyLayer() } }

        let toRoot = transform(of: view)
        let draws = Self.drawsContent(view)
        if let layer = view.layer {
            renderOwnLayer(layer, of: view, drawsContent: draws, toRoot: toRoot, in: ctx)
        } else if draws {
            drawContent(of: view, toRoot: toRoot, in: ctx)
        }

        if view.clipsToBounds || view.layer?.masksToBounds == true {
            // The path is built in the root's space, so the subviews keep the current transform.
            let radius = min(view.layer?.cornerRadius ?? 0, view.bounds.width / 2, view.bounds.height / 2)
            var placement = toRoot
            ctx.addPath(CGPath(
                roundedRect: view.bounds, cornerWidth: radius, cornerHeight: radius, transform: &placement))
            ctx.clip()
        }
        for subview in view.subviews {
            render(subview, in: ctx)
        }
    }

    /// Core Animation's order for one layer: background, contents (here `draw(_:)`), sublayers,
    /// border. The common cases are one `render(in:)`; a view that both draws and carries
    /// sublayers or a border of its own is drawn in three passes so they stay above its drawing.
    private func renderOwnLayer(
        _ layer: CALayer, of view: NSView, drawsContent: Bool, toRoot: CGAffineTransform,
        in ctx: CGContext
    ) {
        let skip = Self.subviewLayers(of: view)
        let own = (layer.sublayers ?? []).filter { !skip.contains(ObjectIdentifier($0)) }

        var restore = LayerOverrides()
        defer { restore.undo() }
        // Drawn on its own, the layer's sublayers must be laid out in the view's coordinates
        // whatever AppKit set relative to a superview's layer.
        restore.set(layer, \.isGeometryFlipped, view.isFlipped)
        // The group alpha is applied by `render(_:in:)`; do not apply it twice.
        if view.alphaValue < 1, layer.opacity == Float(view.alphaValue) { restore.set(layer, \.opacity, 1) }
        for sublayer in layer.sublayers ?? [] where skip.contains(ObjectIdentifier(sublayer)) {
            restore.set(sublayer, \.isHidden, true)
        }

        guard drawsContent else {
            renderLayer(layer, of: view, toRoot: toRoot, in: ctx)
            return
        }
        // `render(in:)` asks a layer's delegate to draw when it has no contents, and a backing
        // layer's delegate is its view: left attached, `draw(_:)` would run once there and once
        // in `drawContent`, and antialiased text drawn twice comes out heavier than on screen.
        // Detached, the drawing happens exactly once, in the order chosen here.
        restore.set(layer, \.delegate, nil)
        guard !own.isEmpty || layer.borderWidth > 0 else {
            renderLayer(layer, of: view, toRoot: toRoot, in: ctx)
            drawContent(of: view, toRoot: toRoot, in: ctx)
            return
        }
        var pass = LayerOverrides()
        for sublayer in own { pass.set(sublayer, \.isHidden, true) }
        pass.set(layer, \.borderWidth, 0)
        renderLayer(layer, of: view, toRoot: toRoot, in: ctx)
        pass.undo()
        drawContent(of: view, toRoot: toRoot, in: ctx)
        pass.set(layer, \.backgroundColor, nil)
        pass.set(layer, \.shadowOpacity, 0)
        renderLayer(layer, of: view, toRoot: toRoot, in: ctx)
        pass.undo()
    }

    /// `render(in:)` draws in the layer's own space, which is y-up; for a flipped view that is
    /// mirrored back into the view's coordinates first.
    private func renderLayer(_ layer: CALayer, of view: NSView, toRoot: CGAffineTransform, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(toRoot)
        if view.isFlipped {
            ctx.concatenate(CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1, tx: 0, ty: layer.bounds.minY + layer.bounds.maxY))
        }
        layer.render(in: ctx)
    }

    /// The view's `draw(_:)`, clipped to its bounds as AppKit clips it.
    private func drawContent(of view: NSView, toRoot: CGAffineTransform, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(toRoot)
        ctx.clip(to: view.bounds)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: view.isFlipped)
        view.draw(view.bounds)
    }
}

/// Temporary layer property changes, undone in reverse order.
@MainActor
private struct LayerOverrides {
    private var undos: [() -> Void] = []

    mutating func set<Value>(_ layer: CALayer, _ keyPath: ReferenceWritableKeyPath<CALayer, Value>, _ value: Value) {
        let old = layer[keyPath: keyPath]
        layer[keyPath: keyPath] = value
        undos.append { layer[keyPath: keyPath] = old }
    }

    mutating func undo() {
        for undo in undos.reversed() { undo() }
        undos = []
    }
}
