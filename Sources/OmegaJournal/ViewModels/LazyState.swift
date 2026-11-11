import SwiftUI

/// View-owned `@Observable` model created lazily, exactly once per view
/// identity — the `@StateObject(wrappedValue:)` ownership semantics.
///
/// `@State private var model = Model()` evaluates `Model()` every time the
/// view struct is initialized and throws the extra instances away. That is
/// fine for cheap models, but `JournalViewModel.init` reads the database and
/// installs `db.onError` (a discarded instance would steal that hook), and
/// tests build `ContentView` structurally without wanting a view model. This
/// wrapper keeps only a cheap holder in `@State` and builds the model on first
/// use, before `body` runs.
@MainActor
@propertyWrapper
struct LazyState<Model: AnyObject & Observable>: DynamicProperty {
    @State private var holder: LazyStateHolder

    init(wrappedValue makeModel: @autoclosure @escaping () -> Model) {
        _holder = State(initialValue: LazyStateHolder { makeModel() })
    }

    var wrappedValue: Model { holder.model(as: Model.self) }

    /// `$model.property` bindings, like `@Bindable`.
    var projectedValue: Bindable<Model> { Bindable(holder.model(as: Model.self)) }

    /// Materializes the model when SwiftUI installs the view, ahead of `body`.
    nonisolated func update() {
        MainActor.assumeIsolated { _ = holder.model(as: Model.self) }
    }
}

/// Storage for `LazyState`. Top-level and non-generic on purpose: Swift
/// 6.3.3's release optimizer crashes (signal 11 in EarlyPerfInliner,
/// `isCallerAndCalleeLayoutConstraintsCompatible`) on the deinit of the
/// generic `LazyState<Model>.Holder` this replaced. The cast back is sound
/// because a holder only ever stores what its own `makeModel` returned.
final class LazyStateHolder {
    private var makeModel: (() -> AnyObject)?
    private var instance: AnyObject?

    init(_ makeModel: @escaping () -> AnyObject) { self.makeModel = makeModel }

    func model<Model: AnyObject>(as _: Model.Type) -> Model {
        if let instance { return unsafeDowncast(instance, to: Model.self) }
        let created = makeModel!()
        instance = created
        makeModel = nil
        return unsafeDowncast(created, to: Model.self)
    }
}
