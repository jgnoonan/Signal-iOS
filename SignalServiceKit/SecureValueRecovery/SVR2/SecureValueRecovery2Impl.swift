//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// Implementation of `SecureValueRecovery` that talks to the SVR2 server.
public class SecureValueRecovery2Impl: SecureValueRecovery {

    private let accountAttributesUpdater: AccountAttributesUpdater
    private let appContext: SVR2.Shims.AppContext
    private let appReadiness: AppReadiness
    private let appVersion: AppVersion
    private let clientWrapper: SVR2ClientWrapper
    private let connectionFactory: SgxWebsocketConnectionFactory
    private let credentialStorage: SVRAuthCredentialStorage
    private let db: any DB
    private let keyDeriver: SVRKeyDeriver
    private let localStorage: SVRLocalStorageInternal
    private let schedulers: Schedulers
    private let storageServiceManager: StorageServiceManager
    private let syncManager: SyncManagerProtocolSwift
    private let tsAccountManager: TSAccountManager
    private let tsConstants: TSConstantsProtocol
    private let twoFAManager: SVR2.Shims.OWS2FAManager

    public convenience init(
        accountAttributesUpdater: AccountAttributesUpdater,
        appContext: SVR2.Shims.AppContext,
        appReadiness: AppReadiness,
        appVersion: AppVersion,
        connectionFactory: SgxWebsocketConnectionFactory,
        credentialStorage: SVRAuthCredentialStorage,
        db: any DB,
        schedulers: Schedulers,
        storageServiceManager: StorageServiceManager,
        svrKeyDeriver: SVRKeyDeriver,
        svrLocalStorage: SVRLocalStorageInternal,
        syncManager: SyncManagerProtocolSwift,
        tsAccountManager: TSAccountManager,
        tsConstants: TSConstantsProtocol,
        twoFAManager: SVR2.Shims.OWS2FAManager
    ) {
        self.init(
            accountAttributesUpdater: accountAttributesUpdater,
            appContext: appContext,
            appReadiness: appReadiness,
            appVersion: appVersion,
            clientWrapper: SVR2ClientWrapperImpl(),
            connectionFactory: connectionFactory,
            credentialStorage: credentialStorage,
            db: db,
            schedulers: schedulers,
            storageServiceManager: storageServiceManager,
            svrKeyDeriver: svrKeyDeriver,
            svrLocalStorage: svrLocalStorage,
            syncManager: syncManager,
            tsAccountManager: tsAccountManager,
            tsConstants: tsConstants,
            twoFAManager: twoFAManager
        )
    }

    private let scheduler: Scheduler

    internal init(
        accountAttributesUpdater: AccountAttributesUpdater,
        appContext: SVR2.Shims.AppContext,
        appReadiness: AppReadiness,
        appVersion: AppVersion,
        clientWrapper: SVR2ClientWrapper,
        connectionFactory: SgxWebsocketConnectionFactory,
        credentialStorage: SVRAuthCredentialStorage,
        db: any DB,
        schedulers: Schedulers,
        storageServiceManager: StorageServiceManager,
        svrKeyDeriver: SVRKeyDeriver,
        svrLocalStorage: SVRLocalStorageInternal,
        syncManager: SyncManagerProtocolSwift,
        tsAccountManager: TSAccountManager,
        tsConstants: TSConstantsProtocol,
        twoFAManager: SVR2.Shims.OWS2FAManager
    ) {
        self.accountAttributesUpdater = accountAttributesUpdater
        self.appContext = appContext
        self.appReadiness = appReadiness
        self.appVersion = appVersion
        self.clientWrapper = clientWrapper
        self.connectionFactory = connectionFactory
        self.credentialStorage = credentialStorage
        self.db = db
        self.localStorage = svrLocalStorage
        self.keyDeriver = svrKeyDeriver
        self.schedulers = schedulers
        self.storageServiceManager = storageServiceManager
        self.syncManager = syncManager
        self.tsAccountManager = tsAccountManager
        self.tsConstants = tsConstants
        self.twoFAManager = twoFAManager

        self.scheduler = schedulers.queue(label: "org.signal.svr2", qos: .userInitiated)
    }

    public func warmCaches() {
        setLocalMasterKeyIfMissing()

        // Require migrations to succeed before we check for old stuff
        // to wipe, because migrations add old stuff to be wiped.
        // If a migration isn't needed, this returns a success immediately.
        migrateEnclavesIfNecessary()?
            .done(on: scheduler) { [weak self] in
                self?.wipeOldEnclavesIfNeeded(auth: .implicit)
                self?.periodicRefreshCredentialIfNecessary()
            }
            .cauterize()
    }

    // MARK: - Periodic Backups

    private static let periodicCredentialRefreshAppVersionKey = "periodicCredentialRefreshAppVersion"

    private func getNeedsCredentialRefreshBasedOnVersion(tx: DBReadTransaction) -> Bool {
        guard
            let lastAppVersion = self.kvStore.getString(
                Self.periodicCredentialRefreshAppVersionKey,
                transaction: tx
            )
        else {
            return true
        }
        return lastAppVersion != appVersion.currentAppVersion
    }

    private func didRefreshCredentialInCurrentVersion(tx: DBWriteTransaction) {
        self.kvStore.setString(
            appVersion.currentAppVersion,
            key: Self.periodicCredentialRefreshAppVersionKey,
            transaction: tx
        )
    }

    private func periodicRefreshCredentialIfNecessary() {
        appReadiness.runNowOrWhenMainAppDidBecomeReadyAsync { [weak self] in
            guard let self else {
                return
            }
            let needsRefresh = self.db.read { tx -> Bool in
                guard self.tsAccountManager.registrationState(tx: tx).isRegistered else {
                    // Only refresh if registered.
                    return false
                }
                guard self.hasBackedUpMasterKey(transaction: tx) else {
                    // If we've never backed up, don't refresh periodically.
                    return false
                }
                return self.getNeedsCredentialRefreshBasedOnVersion(tx: tx)
            }
            guard needsRefresh else {
                return
            }
            // Force refresh a credential, even if we have one cached, to ensure we
            // have a fresh credential to back up.
            Logger.info("Refreshing auth credential for periodic backup")
            RemoteAttestation.authForSVR2(chatServiceAuth: .implicit())
                .observe(on: self.scheduler) { [weak self] result in
                    switch result {
                    case .success(let credential):
                        Logger.info("Storing refreshed credential")
                        self?.db.write { tx in
                            self?.credentialStorage.storeAuthCredentialForCurrentUsername(
                                SVR2AuthCredential(credential: credential),
                                tx
                            )
                            self?.didRefreshCredentialInCurrentVersion(tx: tx)
                        }
                    case .failure:
                        Logger.warn("Unable to fetch auth credential")
                    }
                }
        }
    }

    // MARK: - Key Existence

    public func hasMasterKey(transaction: DBReadTransaction) -> Bool {
        return localStorage.getMasterKey(transaction) != nil
    }

    public func hasBackedUpMasterKey(transaction: DBReadTransaction) -> Bool {
        return localStorage.getIsMasterKeyBackedUp(transaction)
    }

    public func useDeviceLocalMasterKey(authedAccount: AuthedAccount, transaction: DBWriteTransaction) {
        Logger.info("")
        setLocalDataAndSyncStorageServiceIfNeeded(
            masterKey: Randomness.generateRandomBytes(SVR.masterKeyLengthBytes),
            isMasterKeyBackedUp: false,
            pinType: .alphanumeric,
            encodedPINVerificationString: nil,
            mrEnclaveStringValue: nil,
            mode: .syncStorageService(authedAccount),
            transaction: transaction
        )
        // Disable the PIN locally.
        twoFAManager.markDisabled(transaction: transaction)

        // Wipe credentials; they're now useless.
        credentialStorage.removeSVR2CredentialsForCurrentUser(transaction)

        // This will prevent us continuing any in progress backups/exposes.
        // If either are in flight, they will no-op when they get a response
        // and see no in progress backup state.
        clearInProgressBackup(transaction)

        // We should update account attributes so we wipe the reglock and
        // reg recovery password.
        accountAttributesUpdater.scheduleAccountAttributesUpdate(authedAccount: authedAccount, tx: transaction)
    }

    // MARK: - PIN Management

    public func currentPinType(transaction: DBReadTransaction) -> SVR.PinType? {
        return localStorage.getPinType(transaction)
    }

    public func verifyPin(_ pin: String, resultHandler: @escaping (Bool) -> Void) {
        Logger.info("")
        // Kick off to a background thread to do expensive cryptography operations.
        schedulers.global().async { [schedulers, localStorage, db] in
            var isValid = false
            defer {
                schedulers.main.async { resultHandler(isValid) }
            }

            guard let encodedVerificationString = db.read(block: { tx in
                localStorage.getEncodedPINVerificationString(tx)
            }) else {
                owsFailDebug("Attempted to verify pin locally when we don't have a verification string")
                return
            }

            isValid = SVRUtil.verifyPIN(pin: pin, againstEncodedPINVerificationString: encodedVerificationString)
        }
    }

    // MARK: - Key Management

    public func generateAndBackupKeys(pin: String, authMethod: SVR.AuthMethod) -> Promise<Void> {
        let promise: Promise<Data> = self.generateAndBackupKeys(pin: pin, authMethod: authMethod)
        return promise.asVoid(on: schedulers.sync)
    }

    internal func generateAndBackupKeys(pin: String, authMethod: SVR.AuthMethod) -> Promise<Data> {
        Logger.info("backing up")
        return firstly(on: scheduler) { [weak self] () -> Promise<Data> in
            guard let self else {
                return .init(error: SVR.SVRError.assertion)
            }
            let masterKey: Data = {
                // We never change the master key once stored (on the primary).
                if let masterKey = self.db.read(block: { tx in self.localStorage.getMasterKey(tx) }) {
                    return masterKey
                }
                return self.generateMasterKey()
            }()
            return self.doBackupAndExpose(pin: pin, masterKey: masterKey, authMethod: authMethod)
        }
    }

    public func restoreKeys(pin: String, authMethod: SVR.AuthMethod) -> Guarantee<SVR.RestoreKeysResult> {
        Logger.info("")
        // When we restore, we remember which enclave it was from. On some future app startup, we check
        // this enclave, and migrate to a new one if available. This code path relies on that happening
        // asynchronously.
        return doRestore(pin: pin, authMethod: authMethod).map(on: schedulers.sync, \.asSVRResult)
    }

    public func restoreKeysAndBackup(pin: String, authMethod: SVR.AuthMethod) -> Guarantee<SVR.RestoreKeysResult> {
        Logger.info("")

        return doRestore(pin: pin, authMethod: authMethod)
            .then(on: scheduler) { [weak self] restoreResult in
                switch restoreResult {
                case .backupMissing, .invalidPin, .genericError, .networkError, .decryptionError, .unretainedError, .serverError:
                    return .value(restoreResult.asSVRResult)
                case .success(let masterKey, let enclaveWeRestoredFrom):
                    guard let self else {
                        return .value(.genericError(SVR.SVRError.assertion))
                    }
                    // Backup our keys again, even though we just fetched them.
                    // This resets the number of remaining attempts. We always
                    // backup to the current enclave, even if we restored from
                    // a previous enclave.
                    return self
                        .doBackupAndExpose(
                            pin: pin,
                            masterKey: masterKey,
                            authMethod: authMethod
                        )
                        .map(on: self.schedulers.sync) { [weak self] _ in
                            // If the backup succeeds, and the restore was from some old enclave,
                            // delete from that older enclave.
                            if enclaveWeRestoredFrom.stringValue != self?.tsConstants.svr2Enclave.stringValue {
                                // Strictly speaking, this happens in a separate transaction from when we mark the
                                // backup/expose complete. But no matter what this is best effort; the client
                                // can be uninstalled before it gets a chance to delete the old backup, for example.
                                Logger.info("Restored from old enclave and backed up to new enclave; marking old one for deletion.")
                                self?.db.write { tx in
                                    self?.addOldEnclaveToDeleteFrom(enclaveWeRestoredFrom, tx)
                                }
                                self?.wipeOldEnclavesIfNeeded(auth: authMethod)
                            }
                            return .success
                        }
                        .recover(on: self.schedulers.sync) { error in
                            if error.isNetworkFailureOrTimeout {
                                return .value(.networkError(error))
                            }
                            return .value(.genericError(error))
                        }
                }
            }
    }

    public func deleteKeys() -> Promise<Void> {
        Logger.info("")
        return doDelete(
            mrEnclave: tsConstants.svr2Enclave,
            authMethod: .implicit
        ).then(on: scheduler) { [weak self] (result: DeleteResult) -> Promise<Void> in
            // Historically, this has cleared our local keys regardless of whether
            // the remote request succeeded.
            // This is because (a) other state in OWS2FAManager is wiped regardless
            // of outcome, and (b) callsites ignore what the result is.
            // This can probably be revisited at some point.
            self?.db.write { tx in
                self?.clearKeys(transaction: tx)
            }
            switch result {
            case .success:
                return .value(())
            case .unretainedError, .serverError:
                return .init(error: SVR.SVRError.assertion)
            case .genericError(let error), .networkError(let error):
                return .init(error: error)
            }
        }
    }

    public func clearKeys(transaction: DBWriteTransaction) {
        Logger.info("")
        // This will prevent us continuing any in progress backups/exposes.
        // If either are in flight, they will no-op when they get a response
        // and see no in progress backup state.
        clearInProgressBackup(transaction)
        localStorage.clearKeys(transaction)
    }

    public func storeSyncedMasterKey(
        data: Data,
        authedDevice: AuthedDevice,
        updateStorageService: Bool,
        transaction: DBWriteTransaction
    ) {
        Logger.info("")
        let oldMasterKey = localStorage.getMasterKey(transaction)
        localStorage.setMasterKey(data, transaction)

        // Wipe the storage service key, we don't need it anymore.
        localStorage.setSyncedStorageServiceKey(nil, transaction)

        // Trigger a re-fetch of the storage manifest if our keys have changed
        if oldMasterKey != data, updateStorageService {
            storageServiceManager.restoreOrCreateManifestIfNecessary(authedDevice: authedDevice)
        }
    }

    public func masterKeyDataForKeysSyncMessage(tx: DBReadTransaction) -> Data? {
        return localStorage.getMasterKey(tx)
    }

    public func clearSyncedStorageServiceKey(transaction: DBWriteTransaction) {
        Logger.info("")
        localStorage.setSyncedStorageServiceKey(nil, transaction)
        localStorage.setMasterKey(nil, transaction)
    }

    // MARK: - Backup/Expose Request

    private lazy var kvStore = KeyValueStore(collection: "SecureValueRecovery2Impl")

    /// We must be careful to never repeat a backup request when an expose request fails, or
    /// even if an expose request was made. Once we get a success response from a backup
    /// request, we create and persist one of these to track that, and only ever make expose
    /// requests from then on until either:
    /// 1. The expose requests succeeeds (we are done backing up and can wipe this)
    /// 2. The user chooses a different PIN (we will make a new backup request)
    /// 3. The user wipes SVR2 backups
    private struct InProgressBackup: Codable, Equatable {
        let masterKey: Data
        let encryptedMasterKey: Data
        let rawPinType: Int
        let encodedPINVerificationString: String
        // If we make a backup to one mrenclave, then update the mrenclave,
        // we are safe to drop it and start again with a backup to the new
        // mrenclave.
        let mrEnclaveStringValue: String

        func matches(
            pin: String,
            mrEnclave: MrEnclave
        ) -> Bool {
            if !SVRUtil.verifyPIN(pin: pin, againstEncodedPINVerificationString: self.encodedPINVerificationString) {
                return false
            }
            if mrEnclave.stringValue != self.mrEnclaveStringValue {
                return false
            }
            return true
        }

        func matches(_ other: InProgressBackup) -> Bool {
            return self == other
        }

        var pinType: SVR.PinType {
            return SVR.PinType(rawValue: rawPinType) ?? .alphanumeric
        }
    }

    private static let inProgressBackupKey = "InProgressBackup"

    private func getInProgressBackup(_ tx: DBReadTransaction) throws -> InProgressBackup? {
        return try kvStore.getCodableValue(forKey: Self.inProgressBackupKey, transaction: tx)
    }

    private func setInProgressBackup(_ value: InProgressBackup, _ tx: DBWriteTransaction) throws {
        try kvStore.setCodable(optional: value, key: Self.inProgressBackupKey, transaction: tx)
    }

    private func clearInProgressBackup(_ tx: DBWriteTransaction) {
        kvStore.removeValue(forKey: Self.inProgressBackupKey, transaction: tx)
    }

    private func doBackupAndExpose(
        pin: String,
        masterKey: Data,
        authMethod: SVR2.AuthMethod
    ) -> Promise<Data> {
        let config = SVR2WebsocketConfigurator(mrenclave: tsConstants.svr2Enclave, authMethod: authMethod)
        return makeHandshakeAndOpenConnection(config)
            .then(on: scheduler) { [weak self] connection -> Promise<Data> in
                guard let self else {
                    return .init(error: SVR.SVRError.assertion)
                }

                Logger.info("Connection open; beginning backup/expose")
                let weakSelf = Weak(value: self)
                let weakConnection = Weak(value: connection)
                func continueWithExpose(backup: InProgressBackup) -> Promise<Data> {
                    guard let self = weakSelf.value, let connection = weakConnection.value else {
                        return .init(error: SVR.SVRError.assertion)
                    }
                    return self
                        .performExposeRequest(
                            backup: backup,
                            authedAccount: authMethod.authedAccount,
                            connection: connection
                        )
                        .then(on: self.schedulers.sync) { result -> Promise<Data> in
                            switch result {
                            case .success:
                                return .value(backup.masterKey)
                            case .serverError, .networkError, .unretainedError, .localPersistenceError:
                                return .init(error: SVR.SVRError.assertion)
                            }
                        }
                }

                func startFreshBackupExpose() -> Promise<Data> {
                    return self
                        .performBackupRequest(
                            pin: pin,
                            masterKey: masterKey,
                            mrEnclave: config.mrenclave,
                            connection: connection
                        )
                        .then(on: self.scheduler) { (backupResult: BackupResult) -> Promise<Data> in
                            switch backupResult {
                            case .serverError, .networkError, .localPersistenceError, .localEncryptionError, .unretainedError:
                                return .init(error: SVR.SVRError.assertion)
                            case .success(let inProgressBackup):
                                return continueWithExpose(backup: inProgressBackup)
                            }
                        }
                }

                // Check if we had an in flight backup.
                let inProgressBackup: InProgressBackup?
                do {
                    inProgressBackup = try self.db.read(block: self.getInProgressBackup)
                } catch {
                    // If we fail to decode, something has gone wrong locally. But we can
                    // treat this like if we never had a backup; after all the user may uninstall,
                    // reinstall, and do a backup again with the same PIN. This, like that, is
                    // a local-only trigger.
                    Logger.error("Failed to decode in progress backup state")
                    inProgressBackup = nil
                }
                if let inProgressBackup {
                    if inProgressBackup.matches(pin: pin, mrEnclave: config.mrenclave) {
                        // Continue the backup from where we left off.
                        Logger.info("Continuing existing backup with expose")
                        return continueWithExpose(backup: inProgressBackup)
                    } else {
                        // We had an in flight backup, but for a different PIN.
                        // If its expose hasn't started, it should stop itself.
                        Logger.info("Cancelling in progress backup because master key changed")
                        return startFreshBackupExpose()
                    }
                } else {
                    Logger.info("Starting fresh backup + expose")
                    return startFreshBackupExpose()
                }

            }
    }

    private enum BackupResult {
        case success(InProgressBackup)
        case localEncryptionError
        case localPersistenceError
        case networkError
        case serverError
        case unretainedError
    }

    private func performBackupRequest(
        pin: String,
        masterKey: Data,
        mrEnclave: MrEnclave,
        connection: WebsocketConnection
    ) -> Guarantee<BackupResult> {
        guard
            let encodedPINVerificationString = try? SVRUtil.deriveEncodedPINVerificationString(pin: pin)
        else {
            return .value(.localEncryptionError)
        }
        let pinHash: SVR2PinHash
        let encryptedMasterKey: Data
        do {
            pinHash = try connection.hashPin(
                pin: pin,
                wrapper: clientWrapper
            )
            encryptedMasterKey = try pinHash.encryptMasterKey(masterKey)
        } catch {
            return .value(.localEncryptionError)
        }

        var backupRequest = SVR2Proto_BackupRequest()
        backupRequest.maxTries = SVR.maximumKeyAttempts
        backupRequest.pin = pinHash.accessKey
        backupRequest.data = encryptedMasterKey

        var request = SVR2Proto_Request()
        request.backup = backupRequest

        return connection.sendRequestAndReadResponse(request, unretainedError: .unretainedError) { [weak self] makeRequest in
            guard let self else {
                return .value(.unretainedError)
            }
            return makeRequest().map(on: self.scheduler) { [weak self] (response: SVR2Proto_Response) -> BackupResult in
                guard let self else {
                    return .unretainedError
                }
                guard response.hasBackup else {
                    Logger.error("Backup response missing from server")
                    return .serverError
                }
                switch response.backup.status {
                case .ok:
                    Logger.info("Backup success!")
                    let inProgressBackup = InProgressBackup(
                        masterKey: masterKey,
                        encryptedMasterKey: encryptedMasterKey,
                        rawPinType: SVR.PinType(forPin: pin).rawValue,
                        encodedPINVerificationString: encodedPINVerificationString,
                        mrEnclaveStringValue: mrEnclave.stringValue
                    )
                    do {
                        // Write the in progress state to disk; we want to continue
                        // from here and not redo the backup request.
                        try self.db.write { tx in
                            try self.setInProgressBackup(inProgressBackup, tx)
                        }
                    } catch {
                        Logger.error("Failed to serialize in progress backup")
                        return .localPersistenceError
                    }
                    return .success(inProgressBackup)
                case .UNRECOGNIZED, .unset:
                    Logger.error("Unknown backup status response")
                    return .serverError
                }
            }
            .recover(on: self.schedulers.sync) { error in
                Logger.error("Backup failed with closed connection")
                if error.isNetworkFailureOrTimeout {
                    return .value(.networkError)
                } else {
                    return .value(.serverError)
                }
            }
        }
    }

    private enum ExposeResult {
        case success
        case localPersistenceError
        case networkError
        case serverError
        case unretainedError
    }

    private func performExposeRequest(
        backup: InProgressBackup,
        authedAccount: AuthedAccount,
        connection: WebsocketConnection
    ) -> Guarantee<ExposeResult> {
        var exposeRequest = SVR2Proto_ExposeRequest()
        exposeRequest.data = backup.encryptedMasterKey
        var request = SVR2Proto_Request()
        request.expose = exposeRequest
        Logger.info("Issuing expose request")
        return connection.sendRequestAndReadResponse(request, unretainedError: .unretainedError) { [weak self] makeRequest in
            guard let self else {
                return .value(.unretainedError)
            }
            // Check that the backup is still the latest before we actually
            // issue the request.
            let currentBackup: InProgressBackup?
            do {
                currentBackup = try self.db.read { return try self.getInProgressBackup($0) }
            } catch {
                Logger.error("Unable to read in progress backup to continue expose")
                return .value(.localPersistenceError)
            }
            if let currentBackup, backup.matches(currentBackup).negated {
                // This expose is out of date. But its fine to let the caller
                // think it was a success; the backup that took its place
                // is now in charge and this one is done and shouldn't be repeated.
                return .value(.success)
            }
            return makeRequest().map(on: self.scheduler) { [weak self] (response) -> ExposeResult in
                guard let self else {
                    return .unretainedError
                }
                guard response.hasExpose else {
                    Logger.error("Expose response missing from server")
                    return .serverError
                }
                switch response.expose.status {
                case .ok:
                    Logger.info("Expose success!")
                    do {
                        try self.db.write { tx in
                            guard let persistedBackup = try self.getInProgressBackup(tx), persistedBackup.matches(backup) else {
                                Logger.info("Backup state changed while expose ongoing; throwing away results")
                                return
                            }
                            self.clearInProgressBackup(tx)
                            self.setLocalDataAndSyncStorageServiceIfNeeded(
                                masterKey: backup.masterKey,
                                isMasterKeyBackedUp: true,
                                pinType: backup.pinType,
                                encodedPINVerificationString: backup.encodedPINVerificationString,
                                mrEnclaveStringValue: backup.mrEnclaveStringValue,
                                mode: .syncStorageService(authedAccount),
                                transaction: tx
                            )
                        }
                    } catch {
                        Logger.error("Unable to read in progress backup to finalize expose")
                        return .localPersistenceError
                    }
                    return .success
                case .error:
                    // Every expose is a pair with a backup request. For it to fail,
                    // one of three things happened:
                    // 1. The local client sent a second backup, invalidating the one
                    // this expose is paired with.
                    // 2. A second client has sent its own backup, invalidating the
                    // backup this expose is paired with.
                    // 3. The server is misbehaving and reporting an error.
                    //
                    // 1 should be impossible; this class enforces serial execution to
                    // prevent this. It is developer error if it does.
                    //
                    // 2 is impossible; only a primary device does backups, and if there
                    // were another primary this one would be deregistered and its
                    // auth credentials invalidated.
                    //
                    // 3 could be a legitimate server error or a compromised server; in either
                    // case we do NOT want to make another backup; report a failure but keep
                    // any InProgressBackup state around so that retries just retry the expose.
                    // This prevents any possibility of repeated PIN guessing by a compromised server.
                    Logger.error("Got error response when exposing on SVR2 server; something has gone horribly wrong.")
                    return .serverError
                case .UNRECOGNIZED, .unset:
                    Logger.error("Unknown expose status response")
                    return .serverError
                }
            }
            .recover(on: self.schedulers.sync) { error in
                Logger.error("Expose failed with closed connection")
                if error.isNetworkFailureOrTimeout {
                    return .value(.networkError)
                } else {
                    return .value(.serverError)
                }
            }
        }
    }

    // MARK: - Restore Request

    private enum RestoreResult {
        case success(masterKey: Data, mrEnclave: MrEnclave)
        case backupMissing
        case invalidPin(remainingAttempts: UInt32)
        case decryptionError
        case serverError
        case networkError(Error)
        case genericError(Error)
        case unretainedError

        var asSVRResult: SVR.RestoreKeysResult {
            switch self {
            case .success: return .success
            case .backupMissing: return .backupMissing
            case .invalidPin(let remainingAttempts): return .invalidPin(remainingAttempts: remainingAttempts)
            case .networkError(let error): return .networkError(error)
            case .genericError(let error): return .genericError(error)
            case .decryptionError, .serverError, .unretainedError:
                return .genericError(SVR.SVRError.assertion)
            }
        }
    }

    private func doRestore(
        pin: String,
        authMethod: SVR2.AuthMethod
    ) -> Guarantee<RestoreResult> {
        var enclavesToTry = [tsConstants.svr2Enclave] + tsConstants.svr2PreviousEnclaves
        let weakSelf = Weak(value: self)
        func tryNextEnclave() -> Guarantee<RestoreResult> {
            guard enclavesToTry.isEmpty.negated else {
                // If we reach the end, there's no backup.
                return .value(.backupMissing)
            }
            guard let self = weakSelf.value else {
                return .value(.unretainedError)
            }
            let enclave = enclavesToTry.removeFirst()
            return self
                .doRestoreForSpecificEnclave(
                    pin: pin,
                    mrEnclave: enclave,
                    authMethod: authMethod
                )
                .then(on: self.scheduler) { enclaveResult in
                    switch enclaveResult {
                    case .backupMissing:
                        // Only if we get an explicit backup missing result
                        // from the server, try prior enclaves.
                        // This works because we always wipe old enclaves when
                        // we know about newer ones, so the only reason we'd have
                        // anything in an old enclave is that we haven't migrated yet.
                        // Once we migrate, we wipe the old one.
                        return tryNextEnclave()
                    case .success, .invalidPin, .decryptionError, .serverError,
                         .networkError, .genericError, .unretainedError:
                        return .value(enclaveResult)
                    }
                }
        }
        return tryNextEnclave()
    }

    private func doRestoreForSpecificEnclave(
        pin: String,
        mrEnclave: MrEnclave,
        authMethod: SVR2.AuthMethod
    ) -> Guarantee<RestoreResult> {
        let config = SVR2WebsocketConfigurator(mrenclave: mrEnclave, authMethod: authMethod)
        return makeHandshakeAndOpenConnection(config)
            .then(on: scheduler) { [weak self] connection -> Guarantee<RestoreResult> in
                guard let self else {
                    return .value(.unretainedError)
                }
                Logger.info("Connection open; making restore request")
                return self.performRestoreRequest(
                    mrEnclave: mrEnclave,
                    pin: pin,
                    connection: connection,
                    authedAccount: authMethod.authedAccount
                )
            }
            .recover(on: SyncScheduler()) { error in
                if error.isNetworkFailureOrTimeout {
                    return .value(.networkError(error))
                }
                return .value(.genericError(error))
            }
    }

    private func performRestoreRequest(
        mrEnclave: MrEnclave,
        pin: String,
        connection: WebsocketConnection,
        authedAccount: AuthedAccount
    ) -> Guarantee<RestoreResult> {
        let pinHash: SVR2PinHash
        let encodedPINVerificationString: String
        do {
            pinHash = try connection.hashPin(pin: pin, wrapper: clientWrapper)
            encodedPINVerificationString = try SVRUtil.deriveEncodedPINVerificationString(pin: pin)
        } catch {
            return .value(.decryptionError)
        }

        var restoreRequest = SVR2Proto_RestoreRequest()
        restoreRequest.pin = pinHash.accessKey
        var request = SVR2Proto_Request()
        request.restore = restoreRequest
        return connection.sendRequestAndReadResponse(request, unretainedError: .genericError(SVR.SVRError.assertion)) { [weak self] makeRequest in
            guard let self else {
                return .value(.unretainedError)
            }
            return makeRequest().map(on: self.scheduler) { [weak self] (response) -> RestoreResult in
                guard let self else {
                    return .unretainedError
                }
                guard response.hasRestore else {
                    Logger.error("Restore missing in server response")
                    return .serverError
                }
                switch response.restore.status {
                case .unset, .UNRECOGNIZED:
                    Logger.error("Unknown restore status response")
                    return .serverError
                case .missing:
                    Logger.info("Restore response: backup missing")
                    return .backupMissing
                case .pinMismatch:
                    Logger.info("Restore response: invalid pin")
                    return .invalidPin(remainingAttempts: response.restore.tries)
                case .ok:
                    Logger.info("Restore success!")
                    let encryptedMasterKey = response.restore.data
                    do {
                        let masterKey = try pinHash.decryptMasterKey(encryptedMasterKey)
                        self.db.write { tx in
                            self.setLocalDataAndSyncStorageServiceIfNeeded(
                                masterKey: masterKey,
                                isMasterKeyBackedUp: true,
                                pinType: .init(forPin: pin),
                                encodedPINVerificationString: encodedPINVerificationString,
                                mrEnclaveStringValue: mrEnclave.stringValue,
                                mode: .syncStorageService(authedAccount),
                                transaction: tx
                            )
                        }
                        return .success(masterKey: masterKey, mrEnclave: mrEnclave)
                    } catch {
                        Logger.info("Failed to decrypt master key from restore")
                        return .decryptionError
                    }
                }
            }
            .recover(on: self.schedulers.sync) { error -> Guarantee<RestoreResult> in
                Logger.error("Restore failed with closed connection")
                if error.isNetworkFailureOrTimeout {
                    return .value(.networkError(error))
                } else {
                    return .value(.genericError(error))
                }
            }
        }
    }

    // MARK: - Delete Request

    private enum DeleteResult {
        case success
        case serverError
        case networkError(Error)
        case genericError(Error)
        case unretainedError
    }

    private func doDelete(
        mrEnclave: MrEnclave,
        authMethod: SVR2.AuthMethod
    ) -> Guarantee<DeleteResult> {
        let config = SVR2WebsocketConfigurator(mrenclave: mrEnclave, authMethod: authMethod)
        return makeHandshakeAndOpenConnection(config)
            .then(on: scheduler) { [weak self] connection -> Guarantee<DeleteResult> in
                guard let self else {
                    return .value(.unretainedError)
                }
                return self.performDeleteRequest(
                    mrEnclave: mrEnclave,
                    connection: connection,
                    authedAccount: authMethod.authedAccount
                )
            }
            .recover(on: SyncScheduler()) { error in
                if error.isNetworkFailureOrTimeout {
                    return .value(.networkError(error))
                }
                return .value(.genericError(error))
            }
    }

    private func performDeleteRequest(
        mrEnclave: MrEnclave,
        connection: WebsocketConnection,
        authedAccount: AuthedAccount
    ) -> Guarantee<DeleteResult> {
        var request = SVR2Proto_Request()
        request.delete = SVR2Proto_DeleteRequest()
        return connection.sendRequestAndReadResponse(request, unretainedError: .genericError(SVR.SVRError.assertion)) { [weak self] makeRequest in
            guard let self else {
                return .value(.unretainedError)
            }
            return makeRequest().map(on: self.scheduler) { (response) -> DeleteResult in
                guard response.hasDelete else {
                    Logger.error("Delete missing in server response")
                    return .serverError
                }
                Logger.info("Delete success!")
                return .success
            }
            .recover(on: self.schedulers.sync) { error -> Guarantee<DeleteResult> in
                Logger.error("Delete failed with closed connection")
                if error.isNetworkFailureOrTimeout {
                    return .value(.networkError(error))
                } else {
                    return .value(.genericError(error))
                }
            }
        }
    }

    // MARK: Durable deletes

    private static let oldEnclavesToDeleteFromKey = "OldEnclavesToDeleteFrom"

    private func getOldEnclavesToDeleteFrom(_ tx: DBReadTransaction) -> [MrEnclave] {
        // This is decoding a Set<String>. It won't actually ever fail, so just eat up errors.
        let enclaveStrings: Set<String>? = try? kvStore.getCodableValue(
            forKey: Self.oldEnclavesToDeleteFromKey,
            transaction: tx
        )
        guard var enclaveStrings else {
            return []
        }
        var enclavesToDeleteFrom = [MrEnclave]()
        for enclave in tsConstants.svr2PreviousEnclaves {
            if enclaveStrings.remove(enclave.stringValue) != nil {
                enclavesToDeleteFrom.append(enclave)
            }
        }
        return enclavesToDeleteFrom
    }

    private func addOldEnclaveToDeleteFrom(_ enclave: MrEnclave, _ tx: DBWriteTransaction) {
        // This is (en/de)coding a Set<String>. It won't actually ever fail, so just eat up errors.
        var enclaveStrings: Set<String> = (try? kvStore.getCodableValue(
            forKey: Self.oldEnclavesToDeleteFromKey,
            transaction: tx
        )) ?? Set()
        enclaveStrings.insert(enclave.stringValue)
        cleanUpForgottenEnclaves(in: &enclaveStrings)
        try? kvStore.setCodable(enclaveStrings, key: Self.oldEnclavesToDeleteFromKey, transaction: tx)
    }

    private func markOldEnclaveDeleted(_ enclave: MrEnclave, _ tx: DBWriteTransaction) {
        // This is (en/de)coding a Set<String>. It won't actually ever fail, so just eat up errors.
        var enclaveStrings: Set<String> = (try? kvStore.getCodableValue(
            forKey: Self.oldEnclavesToDeleteFromKey,
            transaction: tx
        )) ?? Set()
        enclaveStrings.remove(enclave.stringValue)
        cleanUpForgottenEnclaves(in: &enclaveStrings)
        try? kvStore.setCodable(enclaveStrings, key: Self.oldEnclavesToDeleteFromKey, transaction: tx)
    }

    private func cleanUpForgottenEnclaves(in enclaveStrings: inout Set<String>) {
        let knownEnclaves = Set(tsConstants.svr2PreviousEnclaves.map(\.stringValue))
        enclaveStrings.formIntersection(knownEnclaves)
    }

    private func wipeOldEnclavesIfNeeded(auth: SVR2.AuthMethod) {
        var (isRegistered, enclavesToDeleteFrom) = db.read { tx in
            return (
                self.tsAccountManager.registrationState(tx: tx).isRegistered,
                self.getOldEnclavesToDeleteFrom(tx)
            )
        }
        guard isRegistered else {
            return
        }
        let weakSelf = Weak(value: self)
        func doNextDelete() -> Guarantee<DeleteResult> {
            guard
                let self = weakSelf.value,
                enclavesToDeleteFrom.isEmpty.negated
            else {
                return .value(.unretainedError)
            }
            let enclave = enclavesToDeleteFrom.removeFirst()
            Logger.info("Wiping old enclave: \(enclave.stringValue)")
            return self.doDelete(mrEnclave: enclave, authMethod: auth).then(on: self.scheduler) { result in
                switch result {
                case .success:
                    weakSelf.value?.db.write { tx in
                        weakSelf.value?.markOldEnclaveDeleted(enclave, tx)
                    }
                case .serverError, .networkError, .genericError, .unretainedError:
                    Logger.error("Failed to wipe old enclave; will retry eventually.")
                }
                return doNextDelete()
            }
        }
        _ = doNextDelete()
    }

    // MARK: - Migrations

    /// There was a bug with registration that would allow the user to register without having set a master key,
    /// if they skipped the PIN code entry. What we actually wanted was to not _sync_ that master key with
    /// SVR server, but we still want one locally.
    /// Clean up this state by setting a local-only master key if we are a registered primary without one.
    private func setLocalMasterKeyIfMissing() {
        let (
            hasMasterKey,
            pinCode,
            isRegisteredPrimary
        ) = db.read { tx in
            return (
                self.hasMasterKey(transaction: tx),
                self.twoFAManager.pinCode(transaction: tx),
                self.tsAccountManager.registrationState(tx: tx).isRegisteredPrimaryDevice
            )
        }
        if !hasMasterKey, isRegisteredPrimary {
            db.write { tx in
                if pinCode != nil {
                    // We have a pin code but no master key? We know this has happened
                    // in the wild but have no idea how.
                    Logger.error("Have PIN but no master key")
                }
                self.useDeviceLocalMasterKey(authedAccount: .implicit(), transaction: tx)
            }
        }
    }

    /// If there is a newer enclave than the one we most recently backed up to, backs up known
    /// master key data to it instead, marking the old enclave for deletion.
    /// If there is no migration needed, returns a success promise immediately.
    private func migrateEnclavesIfNecessary() -> Promise<Void>? {
        // Never migrate in the NSE or extensions.
        guard self.appContext.isMainApp else {
            return nil
        }
        return firstly(on: scheduler) { [weak self] () -> (String, String, Data)? in
            return self?.db.read { tx -> (String, String, Data)? in
                guard
                    let self,
                    self.tsAccountManager.registrationState(tx: tx).isRegisteredPrimaryDevice,
                    let masterKey = self.localStorage.getMasterKey(tx),
                    let pin = self.twoFAManager.pinCode(transaction: tx)
                else {
                    // Need to be registered with a master key and PIN to migrate.
                    Logger.info("Not migrating; local state not ready")
                    return nil
                }
                let currentEnclaveString = self.tsConstants.svr2Enclave.stringValue
                let oldSVR2EnclaveString = self.localStorage.getSVR2MrEnclaveStringValue(tx)

                guard self.localStorage.getIsMasterKeyBackedUp(tx) else {
                    // "isMasterKeyBackedUp" is shared between svr2 and kbs; if its
                    // false that means we had no backups to begin with and therefore
                    // should not back up to any new enclave.
                    Logger.info("Not migrating; no previous backups.")
                    return nil
                }

                if
                    let oldSVR2EnclaveString,
                    oldSVR2EnclaveString != currentEnclaveString
                {
                    // We are backed up to an svr2 enclave that isn't the current one.
                    Logger.info("Migrating from old svr2 enclave")
                    return (oldSVR2EnclaveString, pin, masterKey)
                }

                return nil
            }
        }.then(on: scheduler) { [weak self] values -> Promise<Void> in
            guard let self, let (oldSVR2EnclaveString, pin, masterKey) = values else {
                // No migration needed.
                return .value(())
            }

            Logger.info("Migrating SVR2 Enclaves")
            return self
                .doBackupAndExpose(pin: pin, masterKey: masterKey, authMethod: .implicit)
                .done(on: self.scheduler) { [weak self] _ in
                    Logger.info("Successfully migrated SVR2 enclave")
                    guard let self else {
                        return
                    }
                    if
                        let backedUpEnclave = self.tsConstants.svr2PreviousEnclaves.first(where: {
                            $0.stringValue == oldSVR2EnclaveString
                        }) {
                        Logger.info("Adding old enclave to be deleted")
                        // Strictly speaking, this happens in a separate transaction from when we mark the
                        // backup/expose complete. But no matter what this is best effort; the client
                        // can be uninstalled before it gets a chance to delete the old backup, for example.
                        self.db.write { tx in
                            self.addOldEnclaveToDeleteFrom(backedUpEnclave, tx)
                        }
                        // We start wiping any old enclaves right after doing this migration,
                        // no need to kick it off here.
                    }
                }
                .catch(on: self.schedulers.sync) { _ in
                    owsFailDebug("Failed to migrate SVR2 enclave")
                }
        }
    }

    // MARK: - Opening websocket

    /// A connection that manages its own lifecycle and executes all requests in serial.
    ///
    /// In general, we open a connection, make a few requests, and close it.
    /// 1) We ensure all requests happen in serial; if a second request comes in before the first
    ///   has goten a response, we make it wait for the response (and all response handling)
    ///   before continuing.
    /// 2) Instead of managing the open/close in our request creation code, we do that here:
    ///   we keep track of how many requests are going out, decrement when they finish,
    ///   and close the connection when there are none left.
    private class WebsocketConnection {
        private let connection: SgxWebsocketConnection<SVR2WebsocketConfigurator>
        private let scheduler: Scheduler
        private let onDisconnect: () -> Void

        init(
            connection: SgxWebsocketConnection<SVR2WebsocketConfigurator>,
            scheduler: Scheduler,
            onDisconnect: @escaping () -> Void
        ) {
            self.connection = connection
            self.scheduler = scheduler
            self.onDisconnect = onDisconnect
        }

        private var requestQueue = [(Error?) -> Promise<Void>]()
        private var isMakingRequest = false

        private func startNextRequestIfPossible() {
            guard !isMakingRequest else {
                return
            }
            if requestQueue.isEmpty {
                self.scheduleDisconnectIfNeeded()
                return
            }

            let errorToReport: Error?
            switch connectionState {
            case .connected:
                errorToReport = nil
            case .disconnected(let error):
                errorToReport = error
            }

            let nextRequest = requestQueue.removeFirst()
            self.isMakingRequest = true
            nextRequest(errorToReport).ensure(on: scheduler) { [weak self] in
                self?.isMakingRequest = false
                self?.startNextRequestIfPossible()
            }.cauterize()
        }

        /// Should only be called from the scheduler's queue.
        /// - Parameter handler: Called once all previously enqueued requests have gotten a response
        ///  AND executed the contents of their handlers. Anything you want done before another request
        ///  starts should happen before the resolution of the promise returned by this handler.
        func sendRequestAndReadResponse<T>(
            _ request: SVR2Proto_Request,
            unretainedError: T,
            handler: @escaping (() -> Promise<SVR2Proto_Response>) -> Guarantee<T>
        ) -> Guarantee<T> {
            let (returnedGuarantee, returnedFuture) = Guarantee<T>.pending()
            let scheduler = self.scheduler
            requestQueue.append({ [weak self] (initialError: Error?) -> Promise<Void> in
                guard let self else {
                    let guarantee = handler({ return .init(error: SVR.SVRError.assertion) })
                    returnedFuture.resolve(on: scheduler, with: guarantee)
                    return .init(error: SVR.SVRError.assertion)
                }
                if let initialError {
                    let guarantee = handler({ return .init(error: initialError) })
                    returnedFuture.resolve(on: self.scheduler, with: guarantee)
                    return .init(error: SVR.SVRError.assertion)
                }
                let guarantee = handler({
                    return Promise.race(on: self.scheduler, [
                        self.connection.sendRequestAndReadResponse(request),
                        self.deinitFuture.0
                    ])
                    .recover(on: self.scheduler) { [weak self] error in
                        // Treat all errors as terminating the connection.
                        self?.disconnect(error)
                        return Promise<SVR2Proto_Response>.init(error: error)
                    }
                })
                returnedFuture.resolve(on: self.scheduler, with: guarantee)
                return guarantee.asVoid(on: SyncScheduler())
            })
            startNextRequestIfPossible()
            return returnedGuarantee
        }

        private func scheduleDisconnectIfNeeded() {
            // Give a little leeway to start another request, after
            // which if nothing is happening we can close the connection.
            self.scheduler.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                if self?.requestQueue.isEmpty == true, self?.isMakingRequest != true {
                    self?.disconnect(nil)
                }
            }
        }

        private enum ConnectionState {
            case connected
            case disconnected(Error?)

            var isDisconnected: Bool {
                switch self {
                case .connected: return false
                case .disconnected: return true
                }
            }
        }

        private var connectionState = ConnectionState.connected

        private func disconnect(_ error: Error?) {
            guard !connectionState.isDisconnected else {
                return
            }
            connectionState = .disconnected(error)
            connection.disconnect(code: error == nil ? .normalClosure : nil)
            onDisconnect()
        }

        private let deinitFuture = Promise<SVR2Proto_Response>.pending()

        deinit {
            disconnect(SVR.SVRError.assertion)
            let error = SVR.SVRError.assertion
            deinitFuture.1.reject(error)

            // In normal disconnects, the chain of requests continues
            // until all of the handlers are called with the failure.
            // For the deinit case, that stops because the weak self
            // reference dies.
            // To ensure we fail all pending requests, make a copy
            // and fail them in sequence without any self reference.
            let scheduler = self.scheduler
            var requestQueue = self.requestQueue
            func failNextRequestInQueue() {
                guard requestQueue.isEmpty.negated else {
                    return
                }
                requestQueue.removeFirst()(error).ensure(on: scheduler) {
                    failNextRequestInQueue()
                }.cauterize()
            }
            failNextRequestInQueue()
        }

        func hashPin(
            pin: String,
            wrapper: SVR2ClientWrapper
        ) throws -> SVR2PinHash {
            guard
                let utf8NormalizedPin = SVRUtil.normalizePin(pin).data(using: .utf8)
            else {
                throw SVR.SVRError.assertion
            }
            return try wrapper.hashPin(
                connection: connection,
                utf8NormalizedPin: utf8NormalizedPin,
                username: connection.auth.username
            )
        }
    }

    /// Maps from mrenclave string to open connection.
    /// A single connection makes all requests in serial; the next isn't made until we get a response.
    private var openConnectionByMrEnclaveString: [String: WebsocketConnection] = [:]

    private lazy var openConnectionChainedPromise = ChainedPromise<WebsocketConnection?>(initialValue: nil, scheduler: scheduler)

    private func makeHandshakeAndOpenConnection(_ config: SVR2WebsocketConfigurator) -> Promise<WebsocketConnection> {

        // Update the auth method with cached credentials if we have them.
        switch config.authMethod {
        case .svrAuth, .chatServerAuth:
            // If we explicitly want to use some credential, use that.
            break
        case .implicit:
            // If implicit, use any cached values.
            if let cachedCredential: SVR2AuthCredential = db.read(block: credentialStorage.getAuthCredentialForCurrentUser) {
                config.authMethod = .svrAuth(cachedCredential, backup: .implicit)
            }
        }

        let weakSelf = Weak(value: self)
        var innerError: Error = SVR.SVRError.assertion
        func innerConnectAndPerformHandshake() -> Promise<WebsocketConnection?> {
            guard let self = weakSelf.value else {
                return .init(error: SVR.SVRError.assertion)
            }
            if let openConnection = self.openConnectionByMrEnclaveString[config.mrenclave.stringValue] {
                Logger.info("Reusing already open websocket connection")
                return .value(openConnection)
            }
            Logger.info("Opening new connection")
            return self.connectionFactory
                .connectAndPerformHandshake(
                    configurator: config,
                    on: self.scheduler
                )
                .then(on: self.scheduler) { [weak self] connection -> Promise<WebsocketConnection?> in
                    guard let self else {
                        return .init(error: SVR.SVRError.assertion)
                    }
                    let knownGoodAuthCredential = connection.auth
                    let connection = WebsocketConnection(
                        connection: connection,
                        scheduler: self.scheduler,
                        onDisconnect: { [weak self] in
                            self?.openConnectionByMrEnclaveString[config.mrenclave.stringValue] = nil
                        }
                    )
                    self.openConnectionByMrEnclaveString[config.mrenclave.stringValue] = connection

                    // If we were able to open a connection, that means the auth used is valid
                    // and we should cache it.
                    self.db.write { tx in
                        self.credentialStorage.storeAuthCredentialForCurrentUsername(
                            SVR2AuthCredential(credential: knownGoodAuthCredential),
                            tx
                        )
                    }

                    return .value(connection)
                }
                .recover(on: self.schedulers.sync) { [weak self] (error: Error) -> Promise<WebsocketConnection?> in
                    Logger.error("Failed to open websocket connection and complete handshake")
                    innerError = error
                    guard let self else {
                        return .init(error: error)
                    }

                    // if we fail to connect for any reason, assume the credential we tried to use was bad.
                    // clear it out, and if we have a backup, try again with that.
                    switch config.authMethod {
                    case .svrAuth(let attemptedCredential, let backup):
                        self.db.write { tx in
                            self.credentialStorage.deleteInvalidCredentials([attemptedCredential].compacted(), tx)
                        }
                        if let backup {
                            config.authMethod = backup
                            return innerConnectAndPerformHandshake()
                        }
                    case .chatServerAuth, .implicit:
                        break
                    }

                    return .init(error: error)
                }
        }

        return openConnectionChainedPromise.enqueue(recoverValue: nil) { (_: WebsocketConnection?) -> Promise<WebsocketConnection?> in
            innerConnectAndPerformHandshake()
        }.then(on: schedulers.sync) { connection -> Promise<WebsocketConnection> in
            if let connection {
                return .value(connection)
            } else {
                return .init(error: innerError)
            }
        }
    }

    // MARK: - Master key generation

    func generateMasterKey() -> Data {
        return Randomness.generateRandomBytes(SVR.masterKeyLengthBytes)
    }

    // MARK: - Local key storage helpers

    private enum LocalDataUpdateMode {
        case dontSyncStorageService
        case syncStorageService(AuthedAccount)
    }

    private func setLocalDataAndSyncStorageServiceIfNeeded(
        masterKey: Data,
        isMasterKeyBackedUp: Bool,
        pinType: SVR.PinType,
        encodedPINVerificationString: String?,
        mrEnclaveStringValue: String?,
        mode: LocalDataUpdateMode,
        transaction: DBWriteTransaction
    ) {
        localStorage.cleanupDeadKeys(transaction)
        let masterKeyChanged = masterKey != localStorage.getMasterKey(transaction)
        if masterKeyChanged {
            localStorage.setMasterKey(masterKey, transaction)
        }
        if isMasterKeyBackedUp != localStorage.getIsMasterKeyBackedUp(transaction) {
            localStorage.setIsMasterKeyBackedUp(isMasterKeyBackedUp, transaction)
        }
        if pinType != localStorage.getPinType(transaction) {
            localStorage.setPinType(pinType, transaction)
        }
        if encodedPINVerificationString != localStorage.getEncodedPINVerificationString(transaction) {
            localStorage.setEncodedPINVerificationString(encodedPINVerificationString, transaction)
        }
        if mrEnclaveStringValue != localStorage.getSVR2MrEnclaveStringValue(transaction) {
            localStorage.setSVR2MrEnclaveStringValue(mrEnclaveStringValue, transaction)
        }

        // Only continue if we didn't previously have a master key or our master key has changed
        // and we are on the primary device.
        guard
            masterKeyChanged,
            tsAccountManager.registrationState(tx: transaction).isRegisteredPrimaryDevice
        else {
            return
        }

        let authedDeviceForStorageServiceSync: AuthedDevice
        switch mode {
        case .dontSyncStorageService:
            return
        case .syncStorageService(let authedAccount):
            authedDeviceForStorageServiceSync = authedAccount.authedDevice(isPrimaryDevice: true)
        }

        /// When the app is ready, trigger a rotation of the Storage Service
        /// manifest since our SVR master key, which is used to encrypt Storage
        /// Service manifests, has changed and the remote manifest is now
        /// encrypted with out-of-date keys.
        ///
        /// If possible, though, we'll try and preserve Storage Service records,
        /// which may be encrypted with a `recordIkm` in the manifest instead of
        /// the SVR master key. (See: ``StorageServiceRecordIkmMigrator``.)
        ///
        /// It's okay if this doesn't succeed (e.g., the rotation fails or is
        /// interrupted), as the next time we attempt to back up or restore
        /// we'll run into encryption errors, from which we'll automatically
        /// recover by creating a new manifest anyway. However, we might as well
        /// be proactive about that now.
        appReadiness.runNowOrWhenAppDidBecomeReadyAsync { [storageServiceManager, syncManager] in
            Task {
                try? await storageServiceManager.rotateManifest(
                    mode: .preservingRecordsIfPossible,
                    authedDevice: authedDeviceForStorageServiceSync
                )

                // Sync our new keys with linked devices, but wait until the storage
                // service restore is done. That way we avoid the linked device getting
                // the new keys first, failing to decrypt old storage service data,
                // and asking for new keys even though thats not the problem.
                // We don't wanna miss sending one of these, though, so go ahead and send it
                // even if it fails. In any scenario it should eventually recover once
                // both storage service and the linked device have the latest stuff.
                syncManager.sendKeysSyncMessage()
            }
        }
    }
}

fileprivate extension SVR2.AuthMethod {

    var authedAccount: AuthedAccount {
        switch self {
        case .svrAuth(_, let backup):
            return backup?.authedAccount ?? .implicit()
        case .chatServerAuth(let authedAccount):
            return authedAccount
        case .implicit:
            return .implicit()
        }
    }
}