import SwiftUI
import StrandDesign
import WhoopStore

// Correct a finished session: a number missed or mistyped at the gym, a warm-up not marked, or the
// session's RPE. Sets already logged keep their place and order. A set or an exercise that was done but
// never logged can be added: it goes after the last set, with no times of its own, and every figure on
// the session screen is recomputed from these rows.
//
// Fields hold plain text and are parsed once, on Save, so a field is never rewritten while it is being
// typed into (the bug that stored 45.5 kg as 455). Only a field whose text changed is written back:
// re-parsing an untouched pound value into kilograms would otherwise nudge it by a rounding error.

struct LiftSessionEditSheet: View {
    let session: LiftSessionRow
    let sets: [LiftSetRow]
    /// Exercises to open the sheet with one blank new set each, for "Add set" and "Add exercise" on the session screen.
    var startingSets: [NewSetSeed] = []
    /// Called after the changes are written, so the session screen can reload.
    let onSaved: () async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// The text of every field, by set id, and what it held when the sheet opened.
    @State private var form: [String: SetForm] = [:]
    @State private var original: [String: SetForm] = [:]
    @State private var sessionRpeText = ""
    @State private var originalSessionRpe = ""
    @State private var saving = false
    /// Sets added here, not saved yet. A set with no weight and no reps is left out on Save.
    @State private var newSets: [NewSet] = []

    @FocusState private var focused: Field?
    private enum Field: Hashable { case weight(String), reps(String), rpe(String), sessionRpe, newWeight(String), newReps(String), newRpe(String) }

    /// The exercise a new set belongs to, with the muscles it is counted under.
    struct NewSetSeed: Equatable {
        var exercise: String
        var primaryMuscle: LiftMuscle?
        var secondaryMuscles: [LiftMuscle] = []
        init(exercise: String, primaryMuscle: LiftMuscle?, secondaryMuscles: [LiftMuscle] = []) {
            self.exercise = exercise; self.primaryMuscle = primaryMuscle; self.secondaryMuscles = secondaryMuscles
        }
    }

    /// A set being added: its exercise and its fields, as typed.
    struct NewSet: Identifiable, Equatable {
        let id = UUID().uuidString
        var seed: NewSetSeed
        var form = SetForm(weight: "", reps: "", rpe: "", isWarmup: false)
        var isBlank: Bool {
            form.weight.trimmingCharacters(in: .whitespaces).isEmpty && form.reps.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// One set's fields, as typed.
    struct SetForm: Equatable {
        var weight: String
        var reps: String
        var rpe: String
        var isWarmup: Bool
    }

    private var hasChanges: Bool { form != original || sessionRpeText != originalSessionRpe || newSets.contains { !$0.isBlank } }

    /// Exercises in the order they were first performed.
    private var exercises: [String] {
        var seen = Set<String>()
        return sets.sorted { $0.ord < $1.ord }.map(\.exercise).filter { seen.insert($0).inserted }
    }

    /// The logged exercises, then any exercise that only has new sets.
    private var exerciseNames: [String] {
        var names = exercises
        for n in newSets where !names.contains(n.seed.exercise) { names.append(n.seed.exercise) }
        return names
    }

    private var weightHeading: LocalizedStringKey {
        unitSystem == .imperial ? "Lb" : "Kg"
    }

    var body: some View {
        ScreenScaffold(title: "Edit sets",
                       subtitle: "Fix a number, or add a set or an exercise you did but did not log. The session's figures follow when you save.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                sessionRpeCard
                ForEach(exerciseNames, id: \.self) { exerciseCard($0) }
                footer
            }
        }
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 560, height: 780)
        #endif
        .background(StrandPalette.surfaceBase)
        .keyboardDoneToolbar($focused)
        .dismissesKeyboardOnTap($focused)
        .onAppear(perform: fill)
        // The exercise picker can finish dismissing after this sheet has appeared. Keep the
        // pending exercises in sync instead of relying only on the one-time onAppear snapshot.
        .onChange(of: startingSets) { _ in appendStartingSets(startingSets) }
    }

    private var sessionRpeCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("How hard was the whole session? (1–10)").strandOverline()
                field(.sessionRpe, text: Binding(
                    get: { sessionRpeText },
                    set: { sessionRpeText = $0.replacingOccurrences(of: ",", with: ".") }))
            }
        }
    }

    private func exerciseCard(_ exercise: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Text(exercise)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                HStack(spacing: 8) {
                    Text("Set").strandOverline()
                        .frame(width: LiftSessionView.setColumnWidth, alignment: .center)
                    Text(weightHeading).strandOverline().frame(maxWidth: .infinity, alignment: .leading)
                    Text("Reps").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
                    Text("RPE").strandOverline().frame(maxWidth: .infinity, alignment: .leading)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                ForEach(sets.filter { $0.exercise == exercise }.sorted { $0.ord < $1.ord }, id: \.id) {
                    setRow($0)
                }
                let added = newSets.filter { $0.seed.exercise == exercise }
                ForEach(Array(added.enumerated()), id: \.element.id) { position, n in
                    newSetRow(n, number: firstNewIndex(of: exercise) + position)
                }
                Button { addSet(to: exercise) } label: {
                    Label("Add set", systemImage: "plus")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The set number toggles a warm-up, as on the session sheet.
    private func setRow(_ row: LiftSetRow) -> some View {
        let warmup = form[row.id]?.isWarmup ?? row.isWarmup
        return HStack(spacing: 8) {
            Button { form[row.id]?.isWarmup.toggle() } label: {
                Text(warmup ? String(localized: "W") : "\(row.setIndex)")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(warmup ? StrandPalette.metricAmber : StrandPalette.textSecondary)
                    .frame(width: LiftSessionView.setColumnWidth, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(warmup
                                ? String(localized: "Warm-up set — tap to make it a working set")
                                : String(localized: "Set \(row.setIndex) — tap to mark it a warm-up"))
            field(.weight(row.id), text: binding(row.id, \.weight))
            field(.reps(row.id), text: binding(row.id, \.reps))
            field(.rpe(row.id), text: binding(row.id, \.rpe))
        }
        .padding(.vertical, 6)
    }

    /// A set being added: the number toggles a warm-up, the minus takes it back out.
    private func newSetRow(_ n: NewSet, number: Int) -> some View {
        HStack(spacing: 8) {
            Button { toggleNewWarmup(n.id) } label: {
                Text(n.form.isWarmup ? String(localized: "W") : "\(number)")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(n.form.isWarmup ? StrandPalette.metricAmber : StrandPalette.textSecondary)
                    .frame(width: LiftSessionView.setColumnWidth, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            field(.newWeight(n.id), text: newBinding(n.id, \.weight))
            field(.newReps(n.id), text: newBinding(n.id, \.reps))
            field(.newRpe(n.id), text: newBinding(n.id, \.rpe))
            Button { newSets.removeAll { $0.id == n.id } } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove this set"))
        }
        .padding(.vertical, 6)
    }

    /// The number the first new set of an exercise takes: after the last one already logged.
    private func firstNewIndex(of exercise: String) -> Int {
        (sets.filter { $0.exercise == exercise }.map(\.setIndex).max() ?? 0) + 1
    }

    private func addSet(to exercise: String) {
        let known = sets.first { $0.exercise == exercise }
        let seed = newSets.first { $0.seed.exercise == exercise }?.seed
            ?? NewSetSeed(exercise: exercise, primaryMuscle: known?.primaryMuscle, secondaryMuscles: known?.secondaryMuscles ?? [])
        let fresh = NewSet(seed: seed)
        newSets.append(fresh)
        focused = .newWeight(fresh.id)
    }

    private func toggleNewWarmup(_ id: String) {
        if let i = newSets.firstIndex(where: { $0.id == id }) { newSets[i].form.isWarmup.toggle() }
    }

    private func newBinding(_ id: String, _ key: WritableKeyPath<SetForm, String>) -> Binding<String> {
        Binding(get: { newSets.first { $0.id == id }?.form[keyPath: key] ?? "" },
                set: { value in
                    if let i = newSets.firstIndex(where: { $0.id == id }) {
                        newSets[i].form[keyPath: key] = value.replacingOccurrences(of: ",", with: ".")
                    }
                })
    }

    private func field(_ target: Field, text: Binding<String>) -> some View {
        TextField(Self.empty, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .numericKeyboard()
            .focused($focused, equals: target)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A typed comma becomes a point, as on the session sheet: iOS labels the decimal key from the
    /// device's region, and the field reads back in the notation the app displays.
    private func binding(_ id: String, _ key: WritableKeyPath<SetForm, String>) -> Binding<String> {
        Binding(get: { form[id]?[keyPath: key] ?? "" },
                set: { form[id]?[keyPath: key] = $0.replacingOccurrences(of: ",", with: ".") })
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button("Save changes") { Task { await save() } }
                .buttonStyle(.noopPrimary)
                .frame(maxWidth: 180)
                .disabled(saving || !hasChanges)
                .opacity(saving || !hasChanges ? NoopButtonMetrics.disabledOpacity : 1)
        }
    }

    private func fill() {
        if form.isEmpty {
            for row in sets { form[row.id] = Self.form(for: row, system: unitSystem) }
            original = form
            sessionRpeText = session.sessionRpe.map { LiftFormat.trim($0) } ?? ""
            originalSessionRpe = sessionRpeText
        }
        appendStartingSets(startingSets)
    }

    /// Add picker results whether they arrived before or after this sheet's first appearance.
    /// Matching is case-insensitive so repeated SwiftUI updates cannot create duplicate blank sets.
    private func appendStartingSets(_ seeds: [NewSetSeed]) {
        for seed in seeds where !newSets.contains(where: {
            $0.seed.exercise.caseInsensitiveCompare(seed.exercise) == .orderedSame
        }) {
            // An exercise already in the session is matched by name, ignoring case, so its new set joins that card.
            let match = sets.first { $0.exercise.caseInsensitiveCompare(seed.exercise) == .orderedSame }
            let resolved = match.map {
                NewSetSeed(exercise: $0.exercise, primaryMuscle: $0.primaryMuscle, secondaryMuscles: $0.secondaryMuscles)
            } ?? seed
            newSets.append(NewSet(seed: resolved))
        }
    }

    private func save() async {
        guard !saving, let store = await repo.storeHandle() else { return }
        saving = true
        defer { saving = false }

        let edited = sets.compactMap { row -> LiftSetRow? in
            guard let after = form[row.id], let before = original[row.id], after != before else { return nil }
            return Self.applying(after, over: before, to: row, system: unitSystem)
        }
        if !edited.isEmpty { _ = try? await store.upsertLiftSets(edited) }
        let fresh = Self.newRows(from: newSets, session: session, after: sets, system: unitSystem)
        if !fresh.isEmpty { _ = try? await store.upsertLiftSets(fresh) }
        if sessionRpeText != originalSessionRpe {
            var row = session
            row.sessionRpe = LiftFormat.number(sessionRpeText)
            _ = try? await store.upsertLiftSessions([row])
        }
        await onSaved()
        dismiss()
    }

    /// The rows for the sets added here, after the last set of the session. Each takes the next number in its exercise,
    /// has no start or end time of its own, and a set with no weight and no reps is dropped.
    static func newRows(from added: [NewSet], session: LiftSessionRow, after existing: [LiftSetRow],
                        system: UnitSystem) -> [LiftSetRow] {
        var ord = (existing.map(\.ord).max() ?? -1) + 1
        var nextIndex: [String: Int] = [:]
        var rows: [LiftSetRow] = []
        for n in added where !n.isBlank {
            let exercise = n.seed.exercise
            let index = nextIndex[exercise] ?? ((existing.filter { $0.exercise == exercise }.map(\.setIndex).max() ?? 0) + 1)
            nextIndex[exercise] = index + 1
            let blank = SetForm(weight: "", reps: "", rpe: "", isWarmup: n.form.isWarmup)
            let base = LiftSetRow(id: UUID().uuidString, deviceId: session.deviceId, sessionId: session.id, ord: ord,
                                  exercise: exercise, primaryMuscle: n.seed.primaryMuscle, secondaryMuscles: n.seed.secondaryMuscles,
                                  setIndex: index, weightKg: nil, reps: nil, rpe: nil, isWarmup: n.form.isWarmup,
                                  startTs: nil, endTs: nil, restSec: nil, note: nil)
            rows.append(applying(n.form, over: blank, to: base, system: system))
            ord += 1
        }
        return rows
    }

    /// A set's fields as the sheet opens, in the unit the app displays.
    static func form(for row: LiftSetRow, system: UnitSystem) -> SetForm {
        SetForm(weight: row.weightKg.map { LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system)) } ?? "",
                reps: row.reps.map(String.init) ?? "",
                rpe: row.rpe.map { LiftFormat.trim($0) } ?? "",
                isWarmup: row.isWarmup)
    }

    /// `row` with every field that differs between `before` and `after` parsed back in. A blank field
    /// clears its value.
    static func applying(_ after: SetForm, over before: SetForm, to row: LiftSetRow,
                         system: UnitSystem) -> LiftSetRow {
        var edited = row
        if after.weight != before.weight {
            edited.weightKg = LiftFormat.number(after.weight).map {
                LiftFormat.kilograms(fromDisplay: $0, system: system)
            }
        }
        if after.reps != before.reps {
            edited.reps = Int(after.reps.trimmingCharacters(in: .whitespaces))
        }
        if after.rpe != before.rpe {
            edited.rpe = LiftFormat.number(after.rpe)
        }
        edited.isWarmup = after.isWarmup
        return edited
    }

    private static let empty = "—"
}
