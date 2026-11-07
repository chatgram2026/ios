// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Everything the SDK remembers, stored as one JSON value under ``ReviewPromptCenter/stateKey``.
///
/// It stores requests, never "shown": the app cannot know whether the system showed its prompt.
public struct ReviewPromptState: Codable, Equatable, Sendable {
    /// The JSON layout version. Data with a higher version (from a newer SDK) is read but never overwritten.
    public static let currentFormatVersion = 1

    /// The first time the SDK saw this device, or the last ``ReviewPromptCenter/noteFreshStart()``.
    public internal(set) var startDate: Date?
    /// Successful uses per feature, keyed by ``ReviewPromptFeature`` raw value. A string key keeps the counts of a
    /// feature this build does not know (added by a newer version) instead of failing the whole decode.
    public internal(set) var successCounts: [String: Int]
    /// When the system prompt was last asked for.
    public internal(set) var lastRequestDate: Date?
    /// The app version that last asked.
    public internal(set) var lastRequestedAppVersion: String?
    /// ``successCounts`` at the last request: the baseline new successes are counted from. Missing (data written
    /// before the field existed, or no request yet) means zero.
    public internal(set) var successCountsAtLastRequest: [String: Int]

    init() {
        self.startDate = nil
        self.successCounts = [:]
        self.lastRequestDate = nil
        self.lastRequestedAppVersion = nil
        self.successCountsAtLastRequest = [:]
    }

    /// Successful uses of `feature` so far.
    public func successCount(for feature: ReviewPromptFeature) -> Int {
        return self.successCounts[feature.rawValue] ?? 0
    }

    /// Successful uses of `feature` since the last request (all of them before the first request).
    public func newSuccessCount(for feature: ReviewPromptFeature) -> Int {
        let baseline = self.successCountsAtLastRequest[feature.rawValue] ?? 0
        return max(0, self.successCount(for: feature) - baseline)
    }

    /// Moves dates that lie after `now` (the clock was set back) to `now`, so they cannot block requests for months.
    mutating func clampDates(to now: Date) {
        if let startDate = self.startDate, startDate > now {
            self.startDate = now
        }
        if let lastRequestDate = self.lastRequestDate, lastRequestDate > now {
            self.lastRequestDate = now
        }
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion
        case startDate
        case successCounts
        case lastRequestDate
        case lastRequestedAppVersion
        case successCountsAtLastRequest
    }

    private struct CountKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            return nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    // Each field decodes on its own: a bad or missing field reads as empty and never costs the others.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startDate = (try? container.decodeIfPresent(Date.self, forKey: .startDate)) ?? nil
        self.lastRequestDate = (try? container.decodeIfPresent(Date.self, forKey: .lastRequestDate)) ?? nil
        self.lastRequestedAppVersion = (try? container.decodeIfPresent(String.self, forKey: .lastRequestedAppVersion)) ?? nil
        self.successCounts = ReviewPromptState.decodeCounts(in: container, forKey: .successCounts)
        self.successCountsAtLastRequest = ReviewPromptState.decodeCounts(in: container, forKey: .successCountsAtLastRequest)
    }

    // Each entry decodes on its own; a missing or broken dictionary is empty.
    private static func decodeCounts(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [String: Int] {
        var counts: [String: Int] = [:]
        if let countsContainer = try? container.nestedContainer(keyedBy: CountKey.self, forKey: key) {
            for countKey in countsContainer.allKeys {
                if let count = try? countsContainer.decode(Int.self, forKey: countKey), count >= 0 {
                    counts[countKey.stringValue] = count
                }
            }
        }
        return counts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ReviewPromptState.currentFormatVersion, forKey: .formatVersion)
        try container.encodeIfPresent(self.startDate, forKey: .startDate)
        try container.encode(self.successCounts, forKey: .successCounts)
        try container.encodeIfPresent(self.lastRequestDate, forKey: .lastRequestDate)
        try container.encodeIfPresent(self.lastRequestedAppVersion, forKey: .lastRequestedAppVersion)
        // Left out until the first request, so the JSON stays what the first SDK version wrote.
        if !self.successCountsAtLastRequest.isEmpty {
            try container.encode(self.successCountsAtLastRequest, forKey: .successCountsAtLastRequest)
        }
    }

    /// A stored state and the format version it was written with.
    struct Stored: Decodable {
        let formatVersion: Int
        let state: ReviewPromptState

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Data written before the field existed is version 1.
            self.formatVersion = (try? container.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? 1
            self.state = try ReviewPromptState(from: decoder)
        }
    }

    /// The stored state, or nil when `data` is missing or not a JSON object.
    static func decode(_ data: Data?) -> Stored? {
        guard let data = data else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Stored.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(self)
        } catch {
            assertionFailure("ReviewPromptState could not be encoded: \(error)")
            return nil
        }
    }
}
