// Copyright 2026 T-Dash contributors. SPDX-License-Identifier: Apache-2.0
import Foundation

/// A foreground trip. Never integrate across a stale sample or a connection gap.
struct TDTripMeter {
    private(set) var distanceKm: Double = 0
    private(set) var maximumKph: Double = 0
    private(set) var activeSeconds: Double = 0
    private var lastDate: Date?
    private var lastSpeed: Double?

    mutating func ingest(speed: Double?, at date: Date) {
        guard let speed = speed, speed.isFinite, (0...350).contains(speed) else {
            lastDate = nil; lastSpeed = nil; return
        }
        if let previous = lastDate, date <= previous { return }
        maximumKph = max(maximumKph, speed)
        if let previous = lastDate, let previousSpeed = lastSpeed {
            let dt = date.timeIntervalSince(previous)
            if dt > 0 && dt <= 3 {
                distanceKm += (previousSpeed + speed) * 0.5 * dt / 3600
                activeSeconds += dt
            }
        }
        lastDate = date; lastSpeed = speed
    }
    mutating func interrupt() { lastDate = nil; lastSpeed = nil }
    mutating func reset() { self = TDTripMeter() }
}
