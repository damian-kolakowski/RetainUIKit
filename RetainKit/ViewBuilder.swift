import UIKit

// MARK: - ViewNode

/// A node in the view tree built by the declarative builder functions.
/// Each node owns a `UIView` and tracks its children as `ViewNode`s,
/// mirroring the UIKit subview hierarchy.
public class ViewNode {
    public let view: UIView
    public private(set) var children: [ViewNode] = []
    public fileprivate(set) var contentDependencies: [ObjectIdentifier] = []
    public fileprivate(set) var contentClosure: (() -> String)?
    public private(set) weak var parent: ViewNode?

    init(_ view: UIView) {
        self.view = view
    }

    fileprivate func addChild(_ child: ViewNode) {
        children.append(child)
        child.parent = self
        view.addSubview(child.view)
    }

    public var root: ViewNode {
        var current = self
        while let p = current.parent { current = p }
        return current
    }

    /// Override in subclasses to apply a new content string to the underlying view.
    func applyContent(_ title: String) {}

    fileprivate func updateMatchingContent(_ actionDeps: Set<ObjectIdentifier>) {
        if !actionDeps.isDisjoint(with: contentDependencies),
           let newContent = contentClosure?() {
            applyContent(newContent)
        }
        for child in children {
            child.updateMatchingContent(actionDeps)
        }
    }
}

// MARK: - ViewNode subclasses

public final class ContainerViewNode: ViewNode {}

public final class StackViewNode: ViewNode {}

public final class SpaceViewNode: ViewNode {}

public final class PaddingViewNode: ViewNode {}

public final class LabelViewNode: ViewNode {
    public var label: UILabel { view as! UILabel }
    override func applyContent(_ title: String) {
        label.text = title
    }
}

public final class ButtonViewNode: ViewNode {
    public var button: UIButton { view as! UIButton }
    override func applyContent(_ title: String) {
        button.setTitle(title, for: .normal)
    }
}

// MARK: - VerticalStackView

/// A `UIView` subclass that stacks its subviews vertically.
/// During `layoutSubviews`, each child is measured with `sizeToFit()`
/// and positioned directly below the previous one.
public final class VerticalStackView: UIView {
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let sizeThatFits = subview.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            maxWidth = max(maxWidth, sizeThatFits.width)
            subview.frame.origin = CGPoint(x: 0, y: y)
            subview.frame.size = sizeThatFits
            y += sizeThatFits.height
        }
        for subview in subviews {
            subview.frame = CGRect(origin: subview.frame.origin, size: CGSize(width: maxWidth, height: subview.frame.height))
        }
    }
    
    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        var maxWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let sizeThatFits = subview.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            maxWidth = max(maxWidth, sizeThatFits.width)
            totalHeight += sizeThatFits.height
        }
        return CGSize(width: min(maxWidth, size.width), height: min(totalHeight, size.height))
    }

    override public func sizeToFit() {
        var maxWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let sizeThatFits = subview.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            maxWidth = max(maxWidth, sizeThatFits.width)
            totalHeight += sizeThatFits.height
        }
        frame.size = CGSize(width: maxWidth, height: totalHeight)
    }
}

// MARK: - SpaceView

public final class SpaceView: UIView {
    private let fixedHeight: CGFloat

    init(height: CGFloat) {
        self.fixedHeight = height
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override public func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: fixedHeight)
    }

    override public func sizeToFit() {
        frame.size = CGSize(width: frame.width, height: fixedHeight)
    }
}

// MARK: - PaddingView

public final class PaddingView: UIView {
    public let padding: UIEdgeInsets

    public init(padding: UIEdgeInsets) {
        self.padding = padding
        super.init(frame: .zero)
    }

    public convenience init(padding: CGFloat) {
        self.init(padding: UIEdgeInsets(top: padding, left: padding, bottom: padding, right: padding))
    }

    required init?(coder: NSCoder) { fatalError() }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard let child = subviews.first else { return }
        let available = CGSize(
            width:  frame.width  - padding.left - padding.right,
            height: frame.height - padding.top  - padding.bottom
        )
        let childSize = child.sizeThatFits(available)
        child.frame = CGRect(
            x: padding.left,
            y: padding.top,
            width: childSize.width,
            height: childSize.height
        )
    }

    override public func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let available = CGSize(
            width:  size.width  - padding.left - padding.right,
            height: size.height - padding.top  - padding.bottom
        )
        let childSize = child.sizeThatFits(available)
        return CGSize(
            width:  childSize.width  + padding.left + padding.right,
            height: childSize.height + padding.top  + padding.bottom
        )
    }

    override public func sizeToFit() {
        guard let child = subviews.first else { frame.size = .zero; return }
        let childSize = child.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        child.frame = CGRect(x: padding.left, y: padding.top, width: childSize.width, height: childSize.height)
        frame.size = CGSize(
            width:  childSize.width  + padding.left + padding.right,
            height: childSize.height + padding.top  + padding.bottom
        )
    }
}

// MARK: - Builder

// Global stack.  The top element is the node that new nodes are attached to.
private var _viewBuilderStack: [ViewNode] = []
private var _viewNodeAssocKey: UInt8 = 0

private func build<V: UIView, N: ViewNode>(_ make: () -> V, _ makeNode: (V) -> N, _ closure: (V) -> Void) -> N {
    let v = make()
    v.frame = CGRect(x: 0, y: 0, width: 200, height: 44)
    let node = makeNode(v)
    if let parent = _viewBuilderStack.last {
        parent.addChild(node)
    } else {
        // Root node — attach to its UIView so the ViewNode tree lives as long
        // as the UIView hierarchy does.
        objc_setAssociatedObject(v, &_viewNodeAssocKey, node, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    _viewBuilderStack.append(node)
    closure(v)
    _viewBuilderStack.removeLast()
    return node
}

private func build<V: UIView>(_ make: () -> V, _ closure: (V) -> Void) -> ViewNode {
    build(make, { ViewNode($0) }, closure)
}

/// Creates a `UIView`, attaches it to the current parent node, and calls
/// `closure` so child nodes can be declared inside it.
@discardableResult
func container(_ closure: (UIView) -> Void = { _ in }) -> ContainerViewNode {
    build(UIView.init, { ContainerViewNode($0) }, closure)
}

/// Parameter-free variant — use when the container `UIView` doesn't need configuring.
@discardableResult @_disfavoredOverload
func container(_ closure: () -> Void = {}) -> ContainerViewNode {
    build(UIView.init, { ContainerViewNode($0) }) { _ in closure() }
}

/// Creates a `SpaceView` with the given fixed height and attaches it to the current parent node.
@discardableResult
func space(_ height: CGFloat) -> SpaceViewNode {
    build({ SpaceView(height: height) }, { SpaceViewNode($0) }) { _ in }
}

/// Creates a `PaddingView` with the given insets, attaches it to the current parent node, and
/// calls `closure` so child nodes can be declared inside it.
@discardableResult
func padding(_ insets: UIEdgeInsets, _ closure: (PaddingView) -> Void = { _ in }) -> PaddingViewNode {
    build({ PaddingView(padding: insets) }, { PaddingViewNode($0) }, closure)
}

/// Parameter-free variant.
@discardableResult @_disfavoredOverload
func padding(_ insets: UIEdgeInsets, _ closure: () -> Void = {}) -> PaddingViewNode {
    build({ PaddingView(padding: insets) }, { PaddingViewNode($0) }) { _ in closure() }
}

/// Creates a `PaddingView` with uniform padding on all sides.
@discardableResult @_disfavoredOverload
func padding(_ value: CGFloat, _ closure: (PaddingView) -> Void = { _ in }) -> PaddingViewNode {
    build({ PaddingView(padding: value) }, { PaddingViewNode($0) }, closure)
}

/// Parameter-free variant with uniform padding.
@discardableResult @_disfavoredOverload
func padding(_ value: CGFloat, _ closure: () -> Void = {}) -> PaddingViewNode {
    build({ PaddingView(padding: value) }, { PaddingViewNode($0) }) { _ in closure() }
}

@discardableResult @_disfavoredOverload
func padding(_ insets: UIEdgeInsets, _ closure: (PaddingView) -> Void = { _ in }) -> UIView {
    (padding(insets, closure) as PaddingViewNode).view
}

@discardableResult @_disfavoredOverload
func padding(_ insets: UIEdgeInsets, _ closure: () -> Void = {}) -> UIView {
    (padding(insets, closure) as PaddingViewNode).view
}

@discardableResult @_disfavoredOverload
func padding(_ value: CGFloat, _ closure: (PaddingView) -> Void = { _ in }) -> UIView {
    (padding(value, closure) as PaddingViewNode).view
}

@discardableResult @_disfavoredOverload
func padding(_ value: CGFloat, _ closure: () -> Void = {}) -> UIView {
    (padding(value, closure) as PaddingViewNode).view
}

/// Creates a `VerticalStackView`, attaches it to the current parent node, and calls
/// `closure` so child nodes can be declared inside it.
@discardableResult
func stack(_ closure: (VerticalStackView) -> Void = { _ in }) -> StackViewNode {
    build(VerticalStackView.init, { StackViewNode($0) }, closure)
}

/// Parameter-free variant — use when the stack doesn't need configuring.
@discardableResult @_disfavoredOverload
func stack(_ closure: () -> Void = {}) -> StackViewNode {
    build(VerticalStackView.init, { StackViewNode($0) }) { _ in closure() }
}

@discardableResult @_disfavoredOverload
func stack(_ closure: (VerticalStackView) -> Void = { _ in }) -> UIView {
    (stack(closure) as ViewNode).view
}

@discardableResult @_disfavoredOverload
func stack(_ closure: () -> Void = {}) -> UIView {
    (stack(closure) as ViewNode).view
}

/// Creates a `UILabel`, attaches it to the current parent node, sets its
/// text by calling `title()`, and calls `closure` for any further configuration
/// or child nodes.
@discardableResult
func label(title: @escaping () -> String = { "" }, _ closure: (UILabel) -> Void = { _ in }) -> LabelViewNode {
    var contentDeps: [ObjectIdentifier] = []
    let node = build(UILabel.init, { LabelViewNode($0) }) { lbl in
        var titleString = ""
        contentDeps = collectRetainedIdentifiers { titleString = title() }
        lbl.text = titleString
        closure(lbl)
    }
    node.contentDependencies = contentDeps
    node.contentClosure = title
    return node
}

/// Parameter-free variant — use when the `UILabel` itself doesn't need configuring.
@discardableResult @_disfavoredOverload
func label(title: @escaping () -> String = { "" }, _ closure: () -> Void = {}) -> LabelViewNode {
    var contentDeps: [ObjectIdentifier] = []
    let node = build(UILabel.init, { LabelViewNode($0) }) { lbl in
        var titleString = ""
        contentDeps = collectRetainedIdentifiers { titleString = title() }
        lbl.text = titleString
        closure()
    }
    node.contentDependencies = contentDeps
    node.contentClosure = title
    return node
}

@discardableResult @_disfavoredOverload
func label(title: @escaping () -> String = { "" }, _ closure: (UILabel) -> Void = { _ in }) -> UIView {
    (label(title: title, closure) as ViewNode).view
}

@discardableResult @_disfavoredOverload
func label(title: @escaping () -> String = { "" }, _ closure: () -> Void = {}) -> UIView {
    (label(title: title, closure) as ViewNode).view
}

@discardableResult @_disfavoredOverload
func label(_ title: String, _ closure: (UILabel) -> Void = { _ in }) -> ViewNode {
    label(title: { title }, closure)
}

@discardableResult @_disfavoredOverload
func label(_ title: String, _ closure: () -> Void = {}) -> ViewNode {
    label(title: { title }, closure)
}

// MARK: - Tap handler

// Bridges a Swift closure into the Obj-C target/action system.
// Stored on the button via associated objects so it stays alive exactly
// as long as the button does — no manual memory management needed.
private final class _TapHandler: NSObject {
    private let action: () -> Void
    weak var node: ViewNode?
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() {
        let actionDependencies = collectRetainedIdentifiers { action() }
        node?.root.updateMatchingContent(Set(actionDependencies))
        node?.root.view.setNeedsLayout()
    }
}
private var _tapHandlerAssocKey: UInt8 = 0

/// Creates a `UIButton`, attaches it to the current parent node, sets its
/// title by calling `title()`, registers `onTap` as the `.touchUpInside`
/// handler, and calls `closure` for any further configuration or child nodes.
///
/// Usage:
/// ```swift
/// button(title: { "OK" }, onTap: { print("tapped") }) { btn in
///     btn.tintColor = .systemBlue
/// }
/// ```
@discardableResult
func button(title: @escaping () -> String = { "" }, onTap: @escaping () -> Void = {}, _ closure: (UIButton) -> Void = { _ in }) -> ButtonViewNode {
    var contentDeps: [ObjectIdentifier] = []
    let handler = _TapHandler(onTap)
    let node = build({ UIButton(type: .system) }, { ButtonViewNode($0) }) { btn in
        var titleString = ""
        contentDeps = collectRetainedIdentifiers { titleString = title() }
        btn.setTitle(titleString, for: .normal)
        btn.addTarget(handler, action: #selector(_TapHandler.invoke), for: .touchUpInside)
        objc_setAssociatedObject(btn, &_tapHandlerAssocKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        closure(btn)
    }
    handler.node = node
    node.contentDependencies = contentDeps
    node.contentClosure = title
    return node
}

/// Parameter-free variant — use when the `UIButton` itself doesn't need configuring.
@discardableResult @_disfavoredOverload
func button(title: @escaping () -> String = { "" }, onTap: @escaping () -> Void = {}, _ closure: () -> Void = {}) -> ButtonViewNode {
    var contentDeps: [ObjectIdentifier] = []
    let handler = _TapHandler(onTap)
    let node = build({ UIButton(type: .system) }, { ButtonViewNode($0) }) { btn in
        var titleString = ""
        contentDeps = collectRetainedIdentifiers { titleString = title() }
        btn.setTitle(titleString, for: .normal)
        btn.addTarget(handler, action: #selector(_TapHandler.invoke), for: .touchUpInside)
        objc_setAssociatedObject(btn, &_tapHandlerAssocKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        closure()
    }
    handler.node = node
    node.contentDependencies = contentDeps
    node.contentClosure = title
    return node
}
