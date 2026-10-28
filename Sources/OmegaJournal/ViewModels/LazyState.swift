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
    @State private var holder: Holder

    init(wrappedValue makeModel: @autoclosure @escaping () -> Model) {
        _holder = State(initialValue: Holder(makeModel))
    }

    var wrappedValue: Model { holder.model }

    /// `$model.property` bindings, like `@Bindable`.
    var projectedValue: Bindable<Model> { Bindable(holder.model) }

    /// Materializes the model when SwiftUI installs the view, ahead of `body`.
    nonisolated func update() {
        MainActor.assumeIsolated { _ = holder.model }
    }

    final class Holder {
        private var makeModel: (() -> Model)?
        private var instance: Model?

        init(_ makeModel: @escaping () -> Model) { self.makeModel = makeModel }

        var model: Model {
            if let instance { return instance }
            let created = makeModel!()
            instance = created
            makeModel = nil
            return created
        }
    }
}
