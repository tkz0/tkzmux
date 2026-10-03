// SignalsTests — WOR-314 S1. Each handler shape reaches its closure, and every closure box is
// released by GLib's destroy-notify (disconnect, finalization or a failed connection), so the live
// box count returns to its baseline.
import CGtk
import Testing
import TkzGtkShell
import TkzLinuxShim

@Suite(.serialized) @MainActor
struct SignalsTests {
    /// GApplication `activate` is a `void (*)(GApplication *, gpointer)` signal.
    @Test func plainHandlerRunsUntilDisconnected() throws {
        let baseline = Signals.liveBoxes
        let application = try newApplication()
        let first = Counter(), second = Counter()
        let id = Signals.connect(application.pointer, "activate") { first.count += 1 }
        Signals.connect(application.pointer, "activate") { second.count += 1 }
        #expect(id != 0)
        #expect(Signals.liveBoxes == baseline + 2)

        emit(application.pointer, "activate")
        emit(application.pointer, "activate")
        #expect(first.count == 2 && second.count == 2)

        Signals.disconnect(application.pointer, id)
        #expect(Signals.liveBoxes == baseline + 1)
        emit(application.pointer, "activate")
        #expect(first.count == 2 && second.count == 3)
    }

    @Test func finalizationReleasesEveryBox() {
        let baseline = Signals.liveBoxes
        var action: GObjectRef? = GObjectRef(adopting: newAction())
        for _ in 0..<10 {
            Signals.connect(action!.pointer, "activate", withArgument: { _ in })
        }
        #expect(Signals.liveBoxes == baseline + 10)
        action = nil
        #expect(Signals.liveBoxes == baseline)
    }

    /// GSimpleAction `activate` is `void (*)(GSimpleAction *, GVariant *parameter, gpointer)`.
    @Test func argumentHandlerReceivesTheArgument() {
        let action = GObjectRef(adopting: newAction())
        let parameters = Counter()
        Signals.connect(action.pointer, "activate", withArgument: { parameter in
            if parameter == nil { parameters.count += 1 }
        })
        g_action_activate(action.pointer, nil)
        #expect(parameters.count == 1)
    }

    @Test func argumentHandlerReceivesTheParamSpec() {
        let action = GObjectRef(adopting: newAction())
        var names: [String] = []
        Signals.connect(action.pointer, "notify::enabled", withArgument: { spec in
            names.append(String(cString: g_param_spec_get_name(spec!.assumingMemoryBound(to: GParamSpec.self))))
        })
        g_simple_action_set_enabled(action.pointer, 0)
        #expect(names == ["enabled"])
    }

    /// GApplication `name-lost` is a `gboolean (*)(GApplication *, gpointer)` signal with a
    /// true-handled accumulator: true from the first handler stops the emission, false lets the
    /// next handler run.
    @Test func booleanHandlerReturnsItsAnswer() throws {
        let application = try newApplication()
        let first = AnsweringHandler(), second = AnsweringHandler()
        Signals.connect(application.pointer, "name-lost", returning: { first.answer() })
        Signals.connect(application.pointer, "name-lost", returning: { second.answer() })

        #expect(emit(application.pointer, "name-lost") == true)
        #expect(first.calls == 1 && second.calls == 0)

        first.next = false
        #expect(emit(application.pointer, "name-lost") == true)
        #expect(first.calls == 2 && second.calls == 1)
    }

    /// An unknown signal, or a detail on a signal without details, fails to connect (the shim logs
    /// a critical, captured here, and never calls GLib) and the box is released at once, so
    /// nothing leaks.
    @Test(arguments: ["no-such-signal", "activate::detail"])
    func aFailedConnectionReleasesItsBox(signal: String) {
        let baseline = Signals.liveBoxes
        let action = GObjectRef(adopting: newAction())
        let criticals = UnsafeMutablePointer<gint>.allocate(capacity: 1)
        criticals.initialize(to: 0)
        defer { criticals.deallocate() }
        // G_LOG_LEVEL_CRITICAL (1 << 3); the enumerator does not import.
        let handler = g_log_set_handler("TkzLinuxShim", GLogLevelFlags(rawValue: 1 << 3), { _, _, _, count in
            count!.assumingMemoryBound(to: gint.self).pointee += 1
        }, criticals)
        defer { g_log_remove_handler("TkzLinuxShim", handler) }

        let id = Signals.connect(action.pointer, signal) {}
        #expect(id == 0)
        #expect(criticals.pointee == 1)
        #expect(Signals.liveBoxes == baseline)
    }
}

@MainActor
final class AnsweringHandler {
    var next = true
    var calls = 0

    func answer() -> Bool {
        calls += 1
        return next
    }
}

@MainActor
final class Counter {
    var count = 0
}

/// A GApplication that never registers (no session bus needed), transfer full.
@MainActor
func newApplication() throws -> GObjectRef<UnsafeMutablePointer<GApplication>> {
    GObjectRef(adopting: try #require(g_application_new("se.tkz.tkzmux.SignalsTests", tkz_application_non_unique())))
}

/// `g_signal_emit_by_name(application, signal, …)` for a GApplication signal without arguments,
/// through the non-variadic `g_signal_emitv`. Returns the gboolean result for a signal that has
/// one, else nil.
@MainActor @discardableResult
func emit(_ application: UnsafeMutablePointer<GApplication>, _ name: String) -> Bool? {
    var query = GSignalQuery()
    g_signal_query(g_signal_lookup(name, g_application_get_type()), &query)
    var instance = GValue()
    g_value_init(&instance, g_application_get_type())
    g_value_set_object(&instance, application)
    defer { g_value_unset(&instance) }
    let boolean = g_type_from_name("gboolean")
    guard query.return_type == boolean else {
        g_signal_emitv(&instance, query.signal_id, 0, nil)
        return nil
    }
    var result = GValue()
    g_value_init(&result, boolean)
    defer { g_value_unset(&result) }
    g_signal_emitv(&instance, query.signal_id, 0, &result)
    return g_value_get_boolean(&result) != 0
}
