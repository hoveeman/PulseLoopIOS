import Foundation
import OSLog
import SwiftData

/// Versioned snapshot of the persistent schema.
///
/// Adopting `VersionedSchema` + `SchemaMigrationPlan` replaces SwiftData's
/// implicit inference with explicit, reviewable migrations. Implicit inference
/// silently fails on non-additive changes (a renamed/removed/retyped property),
/// which is what risks wiping real user data between TestFlight builds.
///
/// `V1` is the baseline: it lists the models exactly as they ship today, so an
/// existing on-disk store is recognised as already-at-V1 and is left untouched.
///
/// ## Adding the next version — do this on EVERY schema change
/// 1. If the change is non-additive (rename/remove/retype a property, or
///    restructure a model), first **freeze** today's shape: copy the affected
///    `@Model` definitions into a `PulseLoopSchemaV1` namespace so V1 keeps
///    describing the OLD shape after the live models move on. (Purely additive
///    changes — new models, new optional properties — don't need a freeze.)
/// 2. Add `enum PulseLoopSchemaV2: VersionedSchema` with `versionIdentifier`
///    `Schema.Version(2, 0, 0)` and `models` describing the NEW shape.
/// 3. Append a stage to `PulseLoopMigrationPlan.stages`:
///    `.lightweight(fromVersion: PulseLoopSchemaV1.self, toVersion: PulseLoopSchemaV2.self)`
///    for additive / `@Attribute(.originalName:)` renames, or
///    `.custom(...)` when rows need transforming.
/// 4. Point `ModelContainerFactory.currentSchema` at the newest version.
enum PulseLoopSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
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
        ]
    }
}

/// Ordered list of every schema version plus the stages that migrate between
/// adjacent versions. Empty `stages` means V1 is the only version so far.
enum PulseLoopMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PulseLoopSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []  // baseline only — append a stage here when introducing V2 (see PulseLoopSchemaV1 docs).
    }
}

enum ModelContainerFactory {
    private static let log = Logger(subsystem: "com.pulseloop", category: "Persistence")

    /// The newest schema the app builds against. Bump this to the latest
    /// `PulseLoopSchemaVN` whenever a new version is added.
    private static let currentSchema = Schema(versionedSchema: PulseLoopSchemaV1.self)

    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(schema: currentSchema, isStoredInMemoryOnly: inMemory)

        do {
            return try ModelContainer(
                for: currentSchema, migrationPlan: PulseLoopMigrationPlan.self, configurations: [config]
            )
        } catch {
            // In-memory stores have nothing on disk to preserve — surface the failure.
            guard !inMemory else { throw error }
            // The migration plan above handles known version transitions. This is the
            // last-resort net for an unexpected/unmigratable store: move it (and its
            // -wal/-shm sidecars) to a timestamped backup so the data is preserved for
            // recovery, then create a fresh store so the app stays usable — never
            // crash-loop on `fatalError`, never silently drop data.
            log.error("ModelContainer load failed: \(error.localizedDescription, privacy: .public). Backing up store and recreating.")
            backupExistingStore()
            return try ModelContainer(
                for: currentSchema, migrationPlan: PulseLoopMigrationPlan.self, configurations: [config]
            )
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
