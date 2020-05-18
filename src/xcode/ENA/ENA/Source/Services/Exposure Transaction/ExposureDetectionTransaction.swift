//
//  ExposureDetectionTransaction.swift
//  ENA
//
//  Created by Kienle, Christian on 14.05.20.
//  Copyright © 2020 SAP SE. All rights reserved.
//

import Foundation
import ExposureNotification

/// Every time the user wants to know the own risk the app creates an `ExposureDetectionTransaction`.
///
/// The main objective of an `ExposureDetectionTransaction` is to ensure that the
/// exposure detection/risk assesment is done as accurately as possible. An `ExposureDetectionTransaction`
/// requires a delegate to work. The delegate has several high-level tasks:
///
/// - **Provide Information:** Some methods simply provide information/objects that are required by the transaction to do the actual work.
/// - **Consume Results:** At some point the transaction generates results. The delegate is informed about them so that it can consume them.
/// - **React to Errors:** A transaction has several preconditions. If not all of them are met the transaction ends prematurely. In that case the delegate is notified along with a reason that specify details about why the transaction did end prematurely.
///
/// Under the hood the transaction execute the following steps:
///
/// ----
///
/// 1. Determine diagnosis keys that have to be downloaded.
/// 2. Download the missing keys (hours + days).
/// 3. Validate the downloaded data: Check the signatures, decode payloads, …
/// 4. Store everything that is valid and evict invalid/stale data from the local cache.
/// 5. Prepare the actual exposure detection:
///     - Transform keys into a format that can be understood by Apple.
///     - Write transformed data to disk.
///     - Get an `ExposureManager`.
/// 6. Ask for user consent if required.
/// 7. Provide everything to the Exposure Notification framework.
/// 8. Wipe everything and inform the delegate.
final class ExposureDetectionTransaction {
    // MARK: Properties
    private weak var delegate: ExposureDetectionTransactionDelegate?
    private let client: Client
    private let signedPayloadStore: SignedPayloadStore

    // MARK: Creating a Transaction
    init(
        delegate: ExposureDetectionTransactionDelegate,
        client: Client,
        signedPayloadStore: SignedPayloadStore
    ) {
        self.delegate = delegate
        self.client = client
        self.signedPayloadStore = signedPayloadStore
    }

    // MARK: Resuming the Transaction
    func resume() {
        let today = formattedToday()
        client.availableDaysAndHoursUpUntil(today) { result in
            switch result {
            case .success(let daysAndHours):
                self.continueWith(remoteDaysAndHours: daysAndHours)
            case .failure:
                self.endPrematurely(reason: .noDaysAndHours)
            }
        }
    }

    // MARK: Working with the Delegate

    // Ends the transaction prematurely with a given reason.
    private func endPrematurely(reason: DidEndPrematurelyReason) {
        delegate?.exposureDetectionTransaction(self, didEndPrematurely: reason)
    }

    // Informs the delegate about a summary.
    private func didDetectSummary(_ summary: ENExposureDetectionSummary) {
        delegate?.exposureDetectionTransaction(self, didDetectSummary: summary)
    }

    // Gets today formatted as required by the backend.
    private func formattedToday() -> String {
        guard let delegate = delegate else {
            fatalError("ExposureDetectionTransaction requires a delegate to work.")
        }
        return delegate.exposureDetectionTransactionRequiresFormattedToday(self)
    }

    // MARK: Steps of a Transaction

    // 1. Step: Download available Days & Hours
    private func continueWith(remoteDaysAndHours: Client.DaysAndHours) {
        fetchAndStoreMissingDaysAndHours(remoteDaysAndHours: remoteDaysAndHours) { [weak self] in
            guard let self = self else { return }
            self.remoteExposureConfiguration { [weak self] configuration in
                guard let self = self else { return }
                do {
                    let writer = try self.createAppleFilesWriter()
                    self.detectExposures(writer: writer, configuration: configuration)
                } catch {
                    self.endPrematurely(reason: .unableToDiagnosisKeys)
                }
            }
        }
     }

    // 2. Step: Determine and fetch what is missing
    private func fetchAndStoreMissingDaysAndHours(
        remoteDaysAndHours: Client.DaysAndHours,
        completion: @escaping () -> Void
    ) {
        let today = formattedToday()
        let missing = signedPayloadStore.missingDaysAndHours(
            from: remoteDaysAndHours,
            today: today
        )

        client.fetchDays(
            missing.days,
            hours: missing.hours,
            of: formattedToday()
        ) { [weak self] daysAndHours in
            guard let self = self else { return }
            self.signedPayloadStore.addFetchedDaysAndHours(daysAndHours)
            completion()
        }
    }

    // 3. Fetch the Configuration
    private func remoteExposureConfiguration(
        continueWith: @escaping (ENExposureConfiguration) -> Void
    ) {
        client.exposureConfiguration { configuration in
            guard let configuration = configuration else {
                self.endPrematurely(reason: .noExposureConfiguration)
                return
            }

            let fixedConfiguration: ENExposureConfiguration
            if configuration.needsTemporaryFixUntilAppleFixedZeroWeightIssue {
                fixedConfiguration = .mock()
            } else {
                fixedConfiguration = configuration
            }
            continueWith(fixedConfiguration)
        }
    }

    // 4. Get the Manager
    private func withExposureManager(
        useManager: @escaping ExposureDetectionTransactionDelegate.ContinueHandler
    ) {
        guard let delegate = delegate else {
            fatalError("A transaction MUST have a delegate.")
        }

        delegate.exposureDetectionTransaction(
            self,
            continueWithExposureManager: { useManager($0) },
            abort: { _ in
                self.endPrematurely(reason: .noExposureManager)
            }
        )
    }

    // 4. Transform
    private func createAppleFilesWriter() throws -> AppleFilesWriter {
        // 1. Create temp dir
        let fm = FileManager()
        let rootDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true, attributes: nil)
        let buckets = signedPayloadStore.allVerifiedBuckets(today: formattedToday())
        let files = buckets.map { $0.appleFiles }.flatMap { $0 }
        return AppleFilesWriter(rootDir: rootDir, files: files)
    }

    // 5. Execute the actual exposure detection
    private func detectExposures(
        writer: AppleFilesWriter,
        configuration: ENExposureConfiguration
    ) {
        writer.with { [weak self] diagnosisURLs, done in
            guard let self = self else { return }
            self._detectExposures(
                diagnosisKeyURLs: diagnosisURLs,
                configuration: configuration,
                completion: done
            )
        }
    }
    
    private func _detectExposures(
        diagnosisKeyURLs: [URL],
        configuration: ENExposureConfiguration,
        completion: @escaping () -> Void
    ) {
        withExposureManager { manager in
            _ = manager.detectExposures(
                configuration: configuration,
                diagnosisKeyURLs: diagnosisKeyURLs
            ) { [weak self] summary, error in
                guard let self = self else {
                    return
                }
                if let error = error {
                    self.endPrematurely(reason: .noSummary(error))
                    return
                }

                guard let summary = summary else {
                    completion()
                    self.endPrematurely(reason: .noSummary(nil))
                    return
                }
                print("summary: \(summary)")
                print("error: \(String(describing: error))")

                self.didDetectSummary(summary)
                completion()
            }
        }
    }
}

private extension SignedPayloadStore {
    func addFetchedDaysAndHours(_ daysAndHours: FetchedDaysAndHours) {
        let days = daysAndHours.days
        days.bucketsByDay.forEach { day, bucket in
            self.add(day: day, signedPayload: bucket)
        }

        let hours = daysAndHours.hours
        hours.bucketsByHour.forEach { hour, bucket in
            self.add(hour: hour, day: hours.day, signedPayload: bucket)
        }
    }

    func missingDaysAndHours(from remote: Client.DaysAndHours, today: String) -> Client.DaysAndHours {
        let days = missingDays(remoteDays: Set(remote.days))
        let hours = missingHours(
            day: today,
            remoteHours: Set(remote.hours)
        )
        return Client.DaysAndHours(days: Array(days), hours: Array(hours))
    }

    func allKeys(today: String) -> [SignedPayloadProviding] {
        let days = allDailySignedPayloads()
        let hours = hourlySignedPayloads(day: today)
        return days + hours
    }

    func allVerifiedBuckets(today: String) -> [VerifiedSapFileBucket] {
        allKeys(today: today)
            .compactMap { try? VerifiedSapFileBucket(serializedSignedPayload: $0.serializedSignedPayload()) }
            .compactMap { $0 }
    }
}

extension Sap_File {
    func toAppleFile() -> Apple_File {
        Apple_File.with {
            $0.key = self.keys.map { $0.toAppleKey() }
        }
    }
}

extension Sap_Key {
    func toAppleKey() -> Apple_Key {
        Apple_Key.with {
            $0.keyData = self.keyData
            $0.rollingStartNumber = self.rollingStartNumber
            $0.rollingPeriod = self.rollingPeriod
            $0.transmissionRiskLevel = self.transmissionRiskLevel
        }
    }
}

extension VerifiedSapFileBucket: SignedPayloadProviding {
    func serializedSignedPayload() -> Data {
        // swiftlint:disable:next force_try
        try! self.verifiedPayload.signedPayload.serializedData()
    }
}

private extension ENExposureConfiguration {
    var needsTemporaryFixUntilAppleFixedZeroWeightIssue: Bool {
        attenuationWeight.isNearZero ||
            durationWeight.isNearZero ||
            transmissionRiskWeight.isNearZero ||
            daysSinceLastExposureWeight.isNearZero
    }
}

private extension Double {
    var isNearZero: Bool { magnitude < 0.1 }
}