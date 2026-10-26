import Foundation

/// The claude models a schedule's runs can launch with, by their `claude --model` aliases —
/// the same parameter values the CLI takes.
public enum ScheduleModel: String, CaseIterable, Sendable {
    case sonnet, haiku, opus, fable

    /// What a schedule that names no model launches with.
    public static let `default`: ScheduleModel = .opus

    /// The models as `set` words them in a refusal, e.g. "sonnet, haiku, opus or fable".
    public static let spelling = allCases.map(\.rawValue).joined(separator: ", ")
        .replacingOccurrences(of: ", \(fable.rawValue)", with: " or \(fable.rawValue)")

    /// An Anthropic Messages `model` id that names one of these aliases.
    /// `haiku`, `claude-haiku`, and `claude-3-5-haiku-latest` all map to `.haiku`.
    /// An id that names none of them returns nil — the tab keeps claude's own default.
    public init?(anthropicModel raw: String) {
        let tokens = raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let match = Self.allCases.first(where: { tokens.contains($0.rawValue) }) else { return nil }
        self = match
    }
}

/// The effort levels `claude --effort` accepts.
public enum ScheduleEffort: String, CaseIterable, Sendable {
    case low, medium, high, xhigh, max

    /// The levels as `set` words them in a refusal, e.g. "low, medium, high, xhigh or max".
    public static let spelling = allCases.map(\.rawValue).joined(separator: ", ")
        .replacingOccurrences(of: ", \(max.rawValue)", with: " or \(max.rawValue)")
}

/// A prompt sent to a NEW tab, in a folder, on a cron. Plain data, one file per schedule.
public struct Schedule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Also the name of the tab every run opens; follows the tab-name rule (`StationName`).
    public var name: String
    public var cron: String
    public var cwd: String
    public var prompt: String
    /// Runs open scratch tabs unless this is off.
    public var scratch: Bool
    /// A strict JSON Schema (as JSON text) every run's turn must answer with, or nil.
    public var outputSchema: String?
    /// A CC Switch provider id or name, or nil for stock Anthropic.
    public var provider: String?
    /// The claude model every run launches with (a `ScheduleModel` alias), or nil for the
    /// default (opus).
    public var model: String?
    /// The effort level every run launches with (a `ScheduleEffort` value), or nil for
    /// claude's own default.
    public var effort: String?
    public var enabled: Bool
    /// The last cron fire time already dealt with (run, skipped or missed); the next run is
    /// the cron's first fire after it.
    public var lastFire: Date

    public init(id: UUID = UUID(), name: String, cron: String, cwd: String, prompt: String,
                scratch: Bool = true, outputSchema: String? = nil, provider: String? = nil,
                model: String? = nil, effort: String? = nil,
                enabled: Bool = true, lastFire: Date) {
        self.id = id
        self.name = name
        self.cron = cron
        self.cwd = cwd
        self.prompt = prompt
        self.scratch = scratch
        self.outputSchema = outputSchema
        self.provider = provider
        self.model = model
        self.effort = effort
        self.enabled = enabled
        self.lastFire = lastFire
    }
}

/// One run of a schedule, as its index line: when, why, how it ended, and which tab and
/// claude session it ran in. What the run did is that session; nothing of it is copied here.
public struct ScheduleRun: Codable, Equatable, Sendable, Identifiable {
    public enum Trigger: String, Codable, Sendable {
        /// On time.
        case cron
        /// Started by hand (`schedule_run`, the Schedules window).
        case now
        /// A fire that came due while Admiral was closed or the Mac asleep, run on return.
        case late
    }

    public enum Status: String, Codable, Sendable {
        case running, succeeded, failed, timedOut, skipped, missed
    }

    public var id: String
    public var trigger: Trigger
    public var status: Status
    /// The cron fire time the run is for; nil for a run started by hand.
    public var scheduledFor: Date?
    public var startedAt: Date
    public var endedAt: Date?
    public var callsign: String?
    public var sessionID: String?
    /// Why a run failed, was skipped or missed.
    public var note: String?

    public init(id: String = UUID().uuidString.lowercased(), trigger: Trigger, status: Status,
                scheduledFor: Date? = nil, startedAt: Date, endedAt: Date? = nil,
                callsign: String? = nil, sessionID: String? = nil, note: String? = nil) {
        self.id = id
        self.trigger = trigger
        self.status = status
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.callsign = callsign
        self.sessionID = sessionID
        self.note = note
    }
}
