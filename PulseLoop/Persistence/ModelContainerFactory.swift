import Foundation
import OSLog
import SwiftData

enum ModelContainerFactory {
    private static let log = Logger(subsystem: "com.pulseloop", category: "Persistence")

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            Device.self,
            ActivityDaily.self,
            Measurement.self,
            SleepSession.self,
            SleepStageBlock.self,
            RawPacketRow.self,
            DerivedUpdateRow.self,
            UserProfile.self,
            UserGoal.self,
            DeviceMeasurementConfig.self,
            ActivitySession.self,
            ActivitySample.self,
            ActivityBucketSample.self,
            ActivityGpsPoint.self,
            ActivityEvent.self,
            ActivitySensorPollEvent.self,
            CoachConversation.self,
            CoachMessage.self,
            CoachMemory.self,
            CoachToolCall.self,
            CoachNotificationRecord.self,
            CoachSummary.self,
            WearableLog.self
        ])

        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // In-memory stores have nothing on disk to preserve — surface the failure.
            guard !inMemory else { throw error }
            // Additive schema changes (new models / optional properties) migrate automatically
            // via SwiftData's inferred lightweight migration. A non-additive change between
            // builds makes that fail. Rather than `fatalError` (crash-loop on every launch) or
            // let SwiftData silently drop the store, move the existing store aside so the data
            // is preserved for recovery, then create a fresh one so the app stays usable.
            log.error("ModelContainer load failed: \(error.localizedDescription, privacy: .public). Backing up store and recreating.")
            backupExistingStore()
            return try ModelContainer(for: schema, configurations: [config])
        }
    }

    /// Moves the default on-disk store (`default.store` and its `-wal`/`-shm` sidecars) to a
    /// timestamped sibling so a failed migration loses nothing irrecoverably.
    private static func backupExistingStore() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let storePath = appSupport.appending(path: "default.store").path
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let src = storePath + suffix
            guard fm.fileExists(atPath: src) else { continue }
            let dst = storePath + ".backup-\(stamp)" + suffix
            do {
                try fm.moveItem(atPath: src, toPath: dst)
            } catch {
                log.error("Failed to back up \(src, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
