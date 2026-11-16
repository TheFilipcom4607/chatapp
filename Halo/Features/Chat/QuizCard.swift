import SwiftUI

/// The quiz from create_quiz, answered right in the chat: one question at a time, right or wrong
/// with the explanation straight after, then the score, the questions missed, a retry, and a button
/// that sends the results to the model so it can go over the mistakes.
struct QuizCard: View {
    let message: Message
    let conversation: Conversation
    @Environment(ChatEngine.self) private var engine
    /// Questions (indexes into the quiz's questions) whose hint is open.
    @State private var openHints: Set<Int> = []

    var body: some View {
        if let quiz = message.toolState?.quiz {
            VStack(alignment: .leading, spacing: 16) {
                header(quiz)
                progress(quiz)
                if quiz.isShowingResults {
                    results(quiz)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else if let question = quiz.question(at: quiz.attempt.current) {
                    questionView(question, quiz: quiz)
                        .id("\(quiz.history.count)-\(quiz.attempt.order.count)-\(quiz.attempt.current)")
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .glassCard(cornerRadius: 24)
        }
    }

    /// Changes the stored quiz; the answers live on the tool message so they're still there later.
    private func update(_ change: (inout Quiz) -> Void) {
        guard var state = message.toolState, var quiz = state.quiz else { return }
        withAnimation(Motion.snappy) {
            change(&quiz)
            state.quiz = quiz
            message.toolState = state
        }
        engine.save()
    }

    // MARK: Header and progress

    private func header(_ quiz: Quiz) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist.checked")
                .font(.body)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 38, height: 38)
                .background(Theme.fill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(quiz.title)
                    .font(.display(.headline, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(subtitle(quiz))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if quiz.answeredCount > 0, !quiz.isShowingResults {
                Label("\(quiz.correctCount)/\(quiz.answeredCount)", systemImage: "checkmark")
                    .font(.readout(.footnote, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
        }
    }

    private func subtitle(_ quiz: Quiz) -> String {
        let total = quiz.attempt.order.count
        let round = quiz.attempt.onlyMistakes ? "Missed questions · " : ""
        if quiz.isShowingResults { return round + "Results" }
        return round + "Question \(quiz.attempt.current + 1) of \(total)"
    }

    /// One segment per question: green or red once answered, white for the one on screen. Tapping
    /// a segment goes to that question.
    private func progress(_ quiz: Quiz) -> some View {
        HStack(spacing: quiz.attempt.order.count > 20 ? 2 : 4) {
            ForEach(quiz.attempt.order.indices, id: \.self) { step in
                let correct = quiz.isCorrect(at: step)
                let isCurrent = step == quiz.attempt.current
                Button {
                    update { $0.go(to: step) }
                    Haptics.selection()
                } label: {
                    Capsule()
                        .fill(correct == true ? Theme.positive : correct == false ? Theme.negative : isCurrent ? Theme.textPrimary : Theme.fillStrong)
                        .opacity(correct != nil && !isCurrent && !quiz.isShowingResults ? 0.6 : 1)
                        .frame(height: isCurrent ? 6 : 4)
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Question \(step + 1)\(correct == true ? ", right" : correct == false ? ", wrong" : "")")
            }
        }
    }

    // MARK: A question

    private func questionView(_ question: Quiz.Question, quiz: Quiz) -> some View {
        let step = quiz.attempt.current
        let pick = quiz.attempt.picks[step]
        let order = quiz.attempt.optionOrders[step]
        return VStack(alignment: .leading, spacing: 14) {
            MarkdownView(text: question.prompt, baseFont: .body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            if let hint = question.hint, pick == nil {
                hintView(hint, index: quiz.attempt.order[step])
            }

            VStack(spacing: 8) {
                ForEach(Array(order.enumerated()), id: \.offset) { shown, option in
                    optionButton(question.options[option], letter: Quiz.letters[shown],
                                 isAnswer: option == question.answer, isPick: option == pick, revealed: pick != nil) {
                        update { $0.pick(shownIndex: shown) }
                        if option == question.answer { Haptics.success() } else { Haptics.error() }
                    }
                }
            }

            if let pick {
                feedback(question, pick: pick, order: order, step: step, quiz: quiz)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                HStack {
                    Spacer()
                    let last = quiz.nextUnanswered == nil
                    Button {
                        update { $0.advance() }
                        Haptics.tap()
                    } label: {
                        Label(last ? "See results" : "Next", systemImage: last ? "flag.checkered" : "arrow.right")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func optionButton(_ text: String, letter: String, isAnswer: Bool, isPick: Bool, revealed: Bool,
                              action: @escaping () -> Void) -> some View {
        let tint: Color? = revealed ? (isAnswer ? Theme.positive : isPick ? Theme.negative : nil) : nil
        return Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if revealed && (isAnswer || isPick) {
                        Image(systemName: isAnswer ? "checkmark" : "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.onAccent)
                    } else {
                        Text(letter)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 28, height: 28)
                .background(tint ?? Theme.fill, in: Circle())
                MarkdownView(text: text, baseFont: .callout, selectable: false)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background((tint ?? .clear).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint ?? Theme.hairline, lineWidth: tint == nil ? 0.5 : 1.5)
            )
            .opacity(revealed && !isAnswer && !isPick ? 0.5 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        // Not .disabled: that greys the text, and the answers stay worth reading.
        .allowsHitTesting(!revealed)
        .accessibilityLabel("\(letter): \(text)")
        .accessibilityValue(revealed ? (isAnswer ? "Right answer" : isPick ? "Your answer, wrong" : "") : "")
    }

    private func hintView(_ hint: String, index: Int) -> some View {
        let open = openHints.contains(index)
        return Button {
            withAnimation(Motion.snappy) { _ = openHints.insert(index) }
            Haptics.selection()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Theme.textSecondary)
                if open {
                    MarkdownView(text: hint, baseFont: .callout, selectable: false)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Show a hint")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!open)
        .accessibilityLabel(open ? "Hint: \(hint)" : "Show a hint")
    }

    private func feedback(_ question: Quiz.Question, pick: Int, order: [Int], step: Int, quiz: Quiz) -> some View {
        let right = pick == question.answer
        let letter = order.firstIndex(of: question.answer).map { Quiz.letters[$0] } ?? ""
        let busy = engine.isBusy(conversation)
        return VStack(alignment: .leading, spacing: 6) {
            Label(right ? "Right" : "Not quite: the answer is \(letter)", systemImage: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(right ? Theme.positive : Theme.negative)
            if let explanation = question.explanation {
                MarkdownView(text: explanation, baseFont: .callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let ask = quiz.askMessage(at: step) {
                Button {
                    engine.send(text: ask, media: [], in: conversation)
                    Haptics.tap()
                } label: {
                    Label("Ask about this", systemImage: "bubble.left")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Results

    private func results(_ quiz: Quiz) -> some View {
        let total = quiz.attempt.order.count
        let correct = quiz.correctCount
        let fraction = total > 0 ? Double(correct) / Double(total) : 0
        let missed = quiz.missedSteps
        let earlier = quiz.history.dropLast(quiz.attempt.scored ? 1 : 0)
        let busy = engine.isBusy(conversation)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(correct)/\(total)")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.readout(.callout, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict(fraction))
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                if !earlier.isEmpty {
                    Text("Earlier: " + earlier.suffix(4).map { "\($0.correct)/\($0.total)" }.joined(separator: " · "))
                        .font(.readout(.caption))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if !missed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(missed.enumerated()), id: \.element) { i, step in
                        if i > 0 { Divider().overlay(Theme.hairline) }
                        missedRow(quiz, step: step)
                    }
                }
                .padding(.horizontal, 12)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button {
                let text = quiz.resultsMessage
                update { $0.attempt.resultsSent = true }
                engine.send(text: text, media: [], in: conversation)
            } label: {
                Label(quiz.attempt.resultsSent ? "Results sent" : missed.isEmpty ? "Ask for a harder quiz" : "Go over my mistakes",
                      systemImage: quiz.attempt.resultsSent ? "checkmark" : "arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(quiz.attempt.resultsSent || busy)
            .opacity(quiz.attempt.resultsSent || busy ? 0.5 : 1)

            HStack(spacing: 10) {
                if !missed.isEmpty {
                    Button {
                        update { $0.retry(onlyMistakes: true) }
                        Haptics.tap()
                    } label: {
                        Label("Retry missed", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(.haloGlass)
                }
                Button {
                    update { $0.retry(onlyMistakes: false) }
                    Haptics.tap()
                } label: {
                    Label("Start over", systemImage: "shuffle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.haloGlass)
            }
        }
    }

    private func missedRow(_ quiz: Quiz, step: Int) -> some View {
        let question = quiz.question(at: step)
        let pick = quiz.attempt.picks[step]
        return Button {
            update { $0.go(to: step) }
            Haptics.selection()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let question {
                    Text(inline(question.prompt))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)
                    if let pick {
                        Label { Text(inline(question.options[pick])).lineLimit(2) } icon: { Image(systemName: "xmark") }
                            .font(.caption)
                            .foregroundStyle(Theme.negative)
                    }
                    Label { Text(inline(question.options[question.answer])).lineLimit(2) } icon: { Image(systemName: "checkmark") }
                        .font(.caption)
                        .foregroundStyle(Theme.positive)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func verdict(_ fraction: Double) -> String {
        switch fraction {
        case 1: return "Perfect score."
        case 0.8...: return "Nearly there. Retry the ones you missed to lock them in."
        case 0.5...: return "Good start. Go over the misses, then try again."
        default: return "Worth another round once you've gone over the answers."
        }
    }

    /// Bold, italics and code in a one-line summary (math stays as written).
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
