import Foundation

/// A multiple-choice quiz the model wrote for the user to study with, and how they're doing on it.
/// It lives on the tool message, so answers survive relaunches; the model sees them only when the
/// user sends their results.
struct Quiz: Codable, Hashable, Sendable {
    struct Question: Codable, Hashable, Sendable {
        var prompt: String
        var options: [String]
        /// Index into `options` of the right answer.
        var answer: Int
        var explanation: String?
        /// A nudge the user can open before answering; it doesn't give the answer away.
        var hint: String?

        /// A fresh order to show the options in (indexes into `options`). The right answer lands
        /// anywhere, at random. A True/False or Yes/No pair reads in its usual order, and options that
        /// point at the others ("All of the above", "Both A and B") go last, after the shuffled rest.
        func shownOrder() -> [Int] {
            let lowered = options.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            for pair in [["true", "false"], ["yes", "no"]] where Set(lowered) == Set(pair) && lowered.count == 2 {
                return pair.compactMap { lowered.firstIndex(of: $0) }
            }
            let pinned = options.indices.filter { i in
                let o = lowered[i]
                return o.contains("of the above") || o.contains("of these") || o.hasPrefix("both ") || o.hasPrefix("neither ")
            }
            return options.indices.filter { !pinned.contains($0) }.shuffled() + pinned
        }
    }

    /// One run through the quiz, or through the questions missed last time.
    struct Attempt: Codable, Hashable, Sendable {
        /// Indexes into `questions`, in the order they're asked.
        var order: [Int]
        /// For each asked question, the order its options are shown in (indexes into its options).
        var optionOrders: [[Int]]
        /// For each asked question, the option picked (an index into its options); nil until answered.
        var picks: [Int?]
        /// The question on screen; `order.count` once the results show.
        var current: Int
        var onlyMistakes: Bool
        /// The score was added to the history (on first reaching the results).
        var scored: Bool
        /// The results went to the chat.
        var resultsSent: Bool
    }

    struct Score: Codable, Hashable, Sendable {
        var correct: Int
        var total: Int
        var onlyMistakes: Bool
    }

    var title: String
    var questions: [Question]
    var attempt: Attempt
    /// Finished attempts, oldest first.
    var history: [Score]

    static let maxQuestions = 50
    static let maxOptions = 6
    static let letters = ["A", "B", "C", "D", "E", "F"]

    init(title: String, questions: [Question]) {
        self.title = title
        self.questions = questions
        self.history = []
        self.attempt = Self.attempt(of: Array(questions.indices), in: questions, shuffleQuestions: false, onlyMistakes: false)
    }

    /// A fresh attempt. Options are always shuffled (models tend to put the right one second or
    /// third); questions only on a retry, so the first run keeps the model's easy-to-hard order.
    static func attempt(of indexes: [Int], in questions: [Question], shuffleQuestions: Bool, onlyMistakes: Bool) -> Attempt {
        let order = shuffleQuestions ? indexes.shuffled() : indexes
        let optionOrders = order.map { i -> [Int] in
            questions[i].shownOrder()
        }
        return Attempt(order: order, optionOrders: optionOrders, picks: Array(repeating: nil, count: order.count),
                       current: 0, onlyMistakes: onlyMistakes, scored: false, resultsSent: false)
    }

    // MARK: Progress

    var isShowingResults: Bool { attempt.current >= attempt.order.count }
    var answeredCount: Int { attempt.picks.compactMap { $0 }.count }

    func question(at step: Int) -> Question? {
        attempt.order.indices.contains(step) ? questions[attempt.order[step]] : nil
    }

    /// Whether the pick at a step was right; nil while it's unanswered.
    func isCorrect(at step: Int) -> Bool? {
        guard let q = question(at: step), let pick = attempt.picks[step] else { return nil }
        return pick == q.answer
    }

    var correctCount: Int { attempt.order.indices.filter { isCorrect(at: $0) == true }.count }

    /// Steps answered wrongly in this attempt, in the order they were asked.
    var missedSteps: [Int] { attempt.order.indices.filter { isCorrect(at: $0) == false } }

    /// The first unanswered step after the current one, wrapping round; nil when all are answered.
    var nextUnanswered: Int? {
        let n = attempt.order.count
        guard n > 0 else { return nil }
        return (1...n).map { (attempt.current + $0) % n }.first { attempt.picks[$0] == nil }
    }

    // MARK: Changes

    /// Records the option shown at `shownIndex` for the current question; a question is answered once.
    mutating func pick(shownIndex: Int) {
        let step = attempt.current
        guard attempt.picks.indices.contains(step), attempt.picks[step] == nil,
              attempt.optionOrders[step].indices.contains(shownIndex) else { return }
        attempt.picks[step] = attempt.optionOrders[step][shownIndex]
    }

    mutating func go(to step: Int) {
        attempt.current = min(max(0, step), attempt.order.count)
        if isShowingResults { scoreIfNeeded() }
    }

    /// Moves on to the next unanswered question, or to the results once everything's answered.
    mutating func advance() {
        go(to: nextUnanswered ?? attempt.order.count)
    }

    private mutating func scoreIfNeeded() {
        guard !attempt.scored, answeredCount == attempt.order.count else { return }
        attempt.scored = true
        history.append(Score(correct: correctCount, total: attempt.order.count, onlyMistakes: attempt.onlyMistakes))
    }

    /// Starts again with every question, or with just the ones missed this time, in a new order.
    mutating func retry(onlyMistakes: Bool) {
        let indexes = onlyMistakes ? missedSteps.map { attempt.order[$0] } : Array(questions.indices)
        guard !indexes.isEmpty else { return }
        attempt = Self.attempt(of: indexes, in: questions, shuffleQuestions: true, onlyMistakes: onlyMistakes)
    }

    // MARK: Results for the chat

    /// What the user sends to the model from the results, so it can go over the mistakes.
    var resultsMessage: String {
        let total = attempt.order.count
        let correct = correctCount
        let percent = total > 0 ? Int((Double(correct) / Double(total) * 100).rounded()) : 0
        var lines = [attempt.onlyMistakes
            ? "My quiz results for \"\(title)\", retrying the questions I missed: \(correct)/\(total) (\(percent)%)."
            : "My quiz results for \"\(title)\": \(correct)/\(total) (\(percent)%)."]
        let earlier = history.dropLast(attempt.scored ? 1 : 0)
        if !earlier.isEmpty {
            lines.append("Earlier attempts: " + earlier.map { "\($0.correct)/\($0.total)\($0.onlyMistakes ? " (missed ones only)" : "")" }.joined(separator: ", ") + ".")
        }
        let missed = missedSteps
        if missed.isEmpty {
            lines.append("")
            lines.append("I got everything right. Give me a harder quiz on this topic.")
        } else {
            lines.append("")
            lines.append("What I got wrong:")
            for (n, step) in missed.enumerated() {
                guard let q = question(at: step), let pick = attempt.picks[step] else { continue }
                lines.append("\(n + 1). \(Self.oneLine(q.prompt))")
                lines.append("   My answer: \(Self.oneLine(q.options[pick]))")
                lines.append("   Right answer: \(Self.oneLine(q.options[q.answer]))")
            }
            lines.append("")
            lines.append("Go over what I got wrong, then quiz me again on those points.")
        }
        return lines.joined(separator: "\n")
    }

    /// What the user sends to ask the model about one question they've answered.
    func askMessage(at step: Int) -> String? {
        guard let q = question(at: step), let pick = attempt.picks[step] else { return nil }
        var lines = ["About this question from my quiz \"\(title)\": \(Self.oneLine(q.prompt))"]
        if pick == q.answer {
            lines.append("I got it right: \(Self.oneLine(q.options[q.answer])).")
            lines.append("Explain it in more depth, and why the other options are wrong.")
        } else {
            lines.append("I answered \(Self.oneLine(q.options[pick])), but the right answer is \(Self.oneLine(q.options[q.answer])).")
            lines.append("Explain why, and how to tell the two apart next time.")
        }
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Builds a quiz from `create_quiz`'s arguments. The model gives each question's right answer and
/// its wrong ones separately and the card places them at random, so it never has to pick (or
/// miscount) a position. Also forgives the usual slips: letters on the answers, the older
/// `options` + `correct_index` shape, and a question or two that doesn't work.
enum QuizTool {
    static func make(_ args: JSONValue) -> ToolOutcome {
        let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = args["questions"]?.arrayValue ?? []
        var questions: [Quiz.Question] = []
        var skipped = 0
        for item in raw.prefix(Quiz.maxQuestions) {
            if let q = question(item) { questions.append(q) } else { skipped += 1 }
        }
        skipped += max(0, raw.count - Quiz.maxQuestions)
        guard !questions.isEmpty else {
            return .failure("""
            No usable questions. Each one needs `question`, `correct_answer` (one string) and `wrong_answers` \
            (1 to \(Quiz.maxOptions - 1) strings, all different from it), without letters.
            """, summary: "No questions")
        }
        let quiz = Quiz(title: title.isEmpty ? "Quiz" : title, questions: questions)
        let count = "\(questions.count) question\(questions.count == 1 ? "" : "s")"
        var text = """
        The quiz "\(quiz.title)" (\(count)) is shown to the user as an interactive card. They answer one question at a time, \
        see right or wrong with your explanation after each, and get a score at the end; they can retry it or just the ones they missed. \
        Don't repeat the questions or answers in your reply: a short line to start them off is enough. \
        Their answers reach you only if they send their results from the card.
        """
        if skipped > 0 {
            text += "\n\(skipped) question\(skipped == 1 ? " was" : "s were") left out: \(Quiz.maxQuestions) at most, each with a correct_answer and 1 to \(Quiz.maxOptions - 1) different wrong_answers."
        }
        return ToolOutcome(text: text, summary: "\(quiz.title) · \(count)", quiz: quiz)
    }

    static func question(_ item: JSONValue) -> Quiz.Question? {
        func text(_ keys: String...) -> String? {
            for key in keys {
                if let s = item[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
            return nil
        }
        guard let prompt = text("question", "prompt") else { return nil }
        let options: [String]
        let answer: Int
        if let right = text("correct_answer", "right_answer") {
            // The right answer first; shownOrder() moves it somewhere random each attempt.
            let given = (item["wrong_answers"] ?? item["incorrect_answers"])?.arrayValue?.compactMap(\.stringValue) ?? []
            let all = stripAnyLetters(([right] + given).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            var unique: [String] = []
            for option in all where !option.isEmpty && !unique.contains(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) {
                unique.append(option)
            }
            guard all.first?.isEmpty == false else { return nil }
            options = Array(unique.prefix(Quiz.maxOptions))
            answer = 0
        } else {
            let given = (item["options"] ?? item["choices"])?.arrayValue?.compactMap(\.stringValue) ?? []
            options = stripLetters(given.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            guard !options.contains(where: \.isEmpty), let index = answerIndex(item, options: options, original: given) else { return nil }
            answer = index
        }
        guard (2...Quiz.maxOptions).contains(options.count) else { return nil }
        return Quiz.Question(prompt: prompt, options: options, answer: answer,
                             explanation: text("explanation"), hint: text("hint"))
    }

    /// The right option from `correct_index`, or from a letter or the option's own text.
    private static func answerIndex(_ item: JSONValue, options: [String], original: [String]) -> Int? {
        let value = item["correct_index"] ?? item["answer_index"] ?? item["correct"] ?? item["answer"]
        guard let value else { return nil }
        if case .number = value, let i = value.intValue { return options.indices.contains(i) ? i : nil }
        guard let s = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let i = Int(s) { return options.indices.contains(i) ? i : nil }
        let letter = s.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "().: "))
        if letter.count == 1, let i = Quiz.letters.firstIndex(of: letter), options.indices.contains(i) { return i }
        if let i = options.firstIndex(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return i }
        return original.firstIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(s) == .orderedSame }
    }

    /// Drops "A) ", "B. ", "(c) " from the options when every one of them is lettered in order:
    /// the card adds its own letters and shuffles.
    static func stripLetters(_ options: [String]) -> [String] {
        var stripped: [String] = []
        for (i, option) in options.enumerated() {
            guard i < Quiz.letters.count else { return options }
            let letter = Quiz.letters[i]
            let patterns = ["\(letter)) ", "\(letter). ", "\(letter): ", "(\(letter)) ", "\(letter.lowercased())) ", "\(letter.lowercased()). ", "(\(letter.lowercased())) "]
            guard let p = patterns.first(where: { option.hasPrefix($0) }) else { return options }
            stripped.append(String(option.dropFirst(p.count)).trimmingCharacters(in: .whitespaces))
        }
        return stripped
    }

    /// Drops a letter label ("B) ", "(c) ", "D. ") from each answer when every one of them has one,
    /// in any order: separate right and wrong answers carry letters out of order.
    static func stripAnyLetters(_ options: [String]) -> [String] {
        let labels = Quiz.letters.flatMap { l in [l, l.lowercased()].flatMap { ["\($0)) ", "\($0). ", "\($0): ", "(\($0)) "] } }
        let stripped = options.compactMap { option in
            labels.first(where: { option.hasPrefix($0) }).map { String(option.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) }
        }
        return options.count > 1 && stripped.count == options.count ? stripped : options
    }
}
