//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Amplify
import Combine
import Foundation
import AWSPluginsCore

@available(iOS 13.0, *)
class RemoteSyncEngine: RemoteSyncEngineBehavior {

    weak var storageAdapter: StorageEngineAdapter?

    private var dataStoreConfiguration: DataStoreConfiguration

    // Authorization mode strategy
    private var authModeStrategy: AuthModeStrategy

    // Assigned at `start`
    weak var api: APICategoryGraphQLBehavior?
    weak var auth: AuthCategoryBehavior?

    // Assigned and released inside `performInitialQueries`, but we maintain a reference so we can `reset`
    private var initialSyncOrchestrator: InitialSyncOrchestrator?
    private let initialSyncOrchestratorFactory: InitialSyncOrchestratorFactory

    private var syncEventEmitter: SyncEventEmitter?
    private var readyEventEmitter: ReadyEventEmitter?

    private let mutationEventIngester: MutationEventIngester
    let mutationEventPublisher: MutationEventPublisher
    private let outgoingMutationQueue: OutgoingMutationQueueBehavior
    private var outgoingMutationQueueSink: AnyCancellable?

    private var reconciliationQueueSink: AnyCancellable?

    let remoteSyncTopicPublisher: PassthroughSubject<RemoteSyncEngineEvent, DataStoreError>
    var publisher: AnyPublisher<RemoteSyncEngineEvent, DataStoreError> {
        return remoteSyncTopicPublisher.eraseToAnyPublisher()
    }

    /// Synchronizes startup operations
    let workQueue = DispatchQueue(label: "com.amazonaws.RemoteSyncEngineOperationQueue",
                                  target: DispatchQueue.global())

    // Assigned at `setUpCloudSubscriptions`
    var reconciliationQueue: IncomingEventReconciliationQueue?
    var reconciliationQueueFactory: IncomingEventReconciliationQueueFactory

    let stateMachine: StateMachine<State, Action>
    private var stateMachineSink: AnyCancellable?

    var networkReachabilityPublisher: AnyPublisher<ReachabilityUpdate, Never>?
    private var networkReachabilitySink: AnyCancellable?
    var mutationRetryNotifier: MutationRetryNotifier?
    let requestRetryablePolicy: RequestRetryablePolicy
    var currentAttemptNumber: Int

    var finishedCompletionBlock: DataStoreCallback<Void>?

    /// Initializes the CloudSyncEngine with the specified storageAdapter as the provider for persistence of
    /// MutationEvents, sync metadata, and conflict resolution metadata. Immediately initializes the incoming mutation
    /// queue so it can begin accepting incoming mutations from DataStore.
    convenience init(storageAdapter: StorageEngineAdapter,
                     dataStoreConfiguration: DataStoreConfiguration,
                     outgoingMutationQueue: OutgoingMutationQueueBehavior? = nil,
                     initialSyncOrchestratorFactory: InitialSyncOrchestratorFactory? = nil,
                     reconciliationQueueFactory: IncomingEventReconciliationQueueFactory? = nil,
                     stateMachine: StateMachine<State, Action>? = nil,
                     networkReachabilityPublisher: AnyPublisher<ReachabilityUpdate, Never>? = nil,
                     requestRetryablePolicy: RequestRetryablePolicy? = nil) throws {

        let mutationDatabaseAdapter = try AWSMutationDatabaseAdapter(storageAdapter: storageAdapter)
        let awsMutationEventPublisher = AWSMutationEventPublisher(eventSource: mutationDatabaseAdapter)

        // initialize auth strategy
        let resolvedAuthStrategy: AuthModeStrategy = dataStoreConfiguration.authModeStrategyType.resolveStrategy()

        let outgoingMutationQueue = outgoingMutationQueue ??
            OutgoingMutationQueue(storageAdapter: storageAdapter,
                                  dataStoreConfiguration: dataStoreConfiguration,
                                  authModeStrategy: resolvedAuthStrategy)

        let reconciliationQueueFactory = reconciliationQueueFactory ??
            AWSIncomingEventReconciliationQueue.init(modelSchemas:api:storageAdapter:syncExpressions:auth:authModeStrategy:modelReconciliationQueueFactory:)

        let initialSyncOrchestratorFactory = initialSyncOrchestratorFactory ??
            AWSInitialSyncOrchestrator.init(dataStoreConfiguration:authModeStrategy:api:reconciliationQueue:storageAdapter:)

        let resolver = RemoteSyncEngine.Resolver.resolve(currentState:action:)
        let stateMachine = stateMachine ?? StateMachine(initialState: .notStarted,
                                                        resolver: resolver)

        let requestRetryablePolicy = requestRetryablePolicy ?? RequestRetryablePolicy()

        self.init(storageAdapter: storageAdapter,
                  dataStoreConfiguration: dataStoreConfiguration,
                  authModeStrategy: resolvedAuthStrategy,
                  outgoingMutationQueue: outgoingMutationQueue,
                  mutationEventIngester: mutationDatabaseAdapter,
                  mutationEventPublisher: awsMutationEventPublisher,
                  initialSyncOrchestratorFactory: initialSyncOrchestratorFactory,
                  reconciliationQueueFactory: reconciliationQueueFactory,
                  stateMachine: stateMachine,
                  networkReachabilityPublisher: networkReachabilityPublisher,
                  requestRetryablePolicy: requestRetryablePolicy)
    }

    init(storageAdapter: StorageEngineAdapter,
         dataStoreConfiguration: DataStoreConfiguration,
         authModeStrategy: AuthModeStrategy,
         outgoingMutationQueue: OutgoingMutationQueueBehavior,
         mutationEventIngester: MutationEventIngester,
         mutationEventPublisher: MutationEventPublisher,
         initialSyncOrchestratorFactory: @escaping InitialSyncOrchestratorFactory,
         reconciliationQueueFactory: @escaping IncomingEventReconciliationQueueFactory,
         stateMachine: StateMachine<State, Action>,
         networkReachabilityPublisher: AnyPublisher<ReachabilityUpdate, Never>?,
         requestRetryablePolicy: RequestRetryablePolicy) {
        self.storageAdapter = storageAdapter
        self.dataStoreConfiguration = dataStoreConfiguration
        self.authModeStrategy = authModeStrategy
        self.mutationEventIngester = mutationEventIngester
        self.mutationEventPublisher = mutationEventPublisher
        self.outgoingMutationQueue = outgoingMutationQueue
        self.initialSyncOrchestratorFactory = initialSyncOrchestratorFactory
        self.reconciliationQueueFactory = reconciliationQueueFactory
        self.remoteSyncTopicPublisher = PassthroughSubject<RemoteSyncEngineEvent, DataStoreError>()
        self.networkReachabilityPublisher = networkReachabilityPublisher
        self.requestRetryablePolicy = requestRetryablePolicy

        self.currentAttemptNumber = 1

        self.stateMachine = stateMachine
        self.stateMachineSink = self.stateMachine
            .$state
            .sink { [weak self] newState in
                guard let self = self else {
                    return
                }
                self.log.verbose("New state: \(newState)")
                self.workQueue.async {
                    self.respond(to: newState)
                }
        }

        self.authModeStrategy.authDelegate = self
    }

    // swiftlint:disable cyclomatic_complexity
    /// Listens to incoming state changes and invokes the appropriate asynchronous methods in response.
    private func respond(to newState: State) {
        log.verbose("\(#function): \(newState)")

        switch newState {
        case .notStarted:
            break
        case .pausingSubscriptions:
            pauseSubscriptions()
        case .pausingMutationQueue:
            pauseMutations()
        case .clearingStateOutgoingMutations(let storageAdapter):
            clearStateOutgoingMutations(storageAdapter: storageAdapter)
        case .initializingSubscriptions(let api, let storageAdapter):
            initializeSubscriptions(api: api, storageAdapter: storageAdapter)
        case .performingInitialSync:
            performInitialSync()
        case .activatingCloudSubscriptions:
            activateCloudSubscriptions()
        case .activatingMutationQueue(let api, let mutationEventPublisher):
            startMutationQueue(api: api,
                               mutationEventPublisher: mutationEventPublisher)
        case .notifyingSyncStarted:
            notifySyncStarted()

        case .syncEngineActive:
            break

        case .cleaningUp(let error):
            cleanup(error: error)

        case .cleaningUpForTermination:
            cleanupForTermination()

        case .schedulingRestart(let error):
            scheduleRestartOrTerminate(error: error)

        case .terminate:
            terminate()
        }
    }
    // swiftlint:enable cyclomatic_complexity

    func start(api: APICategoryGraphQLBehavior = Amplify.API, auth: AuthCategoryBehavior? = Amplify.Auth) {
        guard storageAdapter != nil else {
            log.error(error: DataStoreError.nilStorageAdapter())
            remoteSyncTopicPublisher.send(completion: .failure(DataStoreError.nilStorageAdapter()))
            return
        }
        self.api = api
        self.auth = auth

        if networkReachabilityPublisher == nil,
            let reachability = api as? APICategoryReachabilityBehavior {
            do {
                networkReachabilityPublisher = try reachability.reachabilityPublisher()
            } catch {
                log.error("\(#function): Unable to listen on reachability: \(error)")
            }
        }

        networkReachabilitySink =
            networkReachabilityPublisher?
            .sink(receiveValue: onReceiveNetworkStatus(networkStatus:))

        remoteSyncTopicPublisher.send(.storageAdapterAvailable)
        stateMachine.notify(action: .receivedStart)
    }

    func stop(completion: @escaping DataStoreCallback<Void>) {
        stateMachine.notify(action: .finished)
        if finishedCompletionBlock == nil {
            finishedCompletionBlock = completion
        }
    }

    func terminate() {
        remoteSyncTopicPublisher.send(completion: .finished)
        cancelEmitters()
        if let completionBlock = finishedCompletionBlock {
            completionBlock(.successfulVoid)
            finishedCompletionBlock = nil
        }
    }

    func submit(_ mutationEvent: MutationEvent) -> Future<MutationEvent, DataStoreError> {
        return mutationEventIngester.submit(mutationEvent: mutationEvent)
    }

    // MARK: - Startup sequence
    private func pauseSubscriptions() {
        log.debug(#function)
        reconciliationQueue?.pause()

        remoteSyncTopicPublisher.send(.subscriptionsPaused)
        stateMachine.notify(action: .pausedSubscriptions)
    }

    private func pauseMutations() {
        log.debug(#function)
        outgoingMutationQueue.stopSyncingToCloud {
            self.remoteSyncTopicPublisher.send(.mutationsPaused)
            if let storageAdapter = self.storageAdapter {
                self.stateMachine.notify(action: .pausedMutationQueue(storageAdapter))
            }
        }
    }

    private func clearStateOutgoingMutations(storageAdapter: StorageEngineAdapter) {
        log.debug(#function)
        let mutationEventClearState = MutationEventClearState(storageAdapter: storageAdapter)
        mutationEventClearState.clearStateOutgoingMutations {
            if let api = self.api {
                self.remoteSyncTopicPublisher.send(.clearedStateOutgoingMutations)
                self.stateMachine.notify(action: .clearedStateOutgoingMutations(api, storageAdapter))
            }
        }
    }

    private func initializeSubscriptions(api: APICategoryGraphQLBehavior,
                                         storageAdapter: StorageEngineAdapter) {
        log.debug(#function)
        let syncableModelSchemas = ModelRegistry.modelSchemas.filter { $0.isSyncable }
        reconciliationQueue = reconciliationQueueFactory(syncableModelSchemas,
                                                         api,
                                                         storageAdapter,
                                                         dataStoreConfiguration.syncExpressions,
                                                         auth,
                                                         authModeStrategy,
                                                         nil)
        reconciliationQueueSink = reconciliationQueue?.publisher.sink(
            receiveCompletion: onReceiveCompletion(receiveCompletion:),
            receiveValue: onReceive(receiveValue:))
    }

    private func performInitialSync() {
        log.debug(#function)

        let initialSyncOrchestrator = initialSyncOrchestratorFactory(dataStoreConfiguration,
                                                                     authModeStrategy,
                                                                     api,
                                                                     reconciliationQueue,
                                                                     storageAdapter)

        // Hold a reference so we can `reset` while initial sync is in process
        self.initialSyncOrchestrator = initialSyncOrchestrator

        syncEventEmitter = SyncEventEmitter(initialSyncOrchestrator: initialSyncOrchestrator,
                                            reconciliationQueue: reconciliationQueue)

        readyEventEmitter = ReadyEventEmitter(remoteSyncEnginePublisher: publisher,
                                              completion: { self.cancelEmitters() })

        // TODO: This should be an AsynchronousOperation, not a semaphore-waited block
        let semaphore = DispatchSemaphore(value: 0)

        initialSyncOrchestrator.sync { result in
            if case .failure(let dataStoreError) = result {
                self.log.error(dataStoreError.errorDescription)
                self.log.error(dataStoreError.recoverySuggestion)
                if let underlyingError = dataStoreError.underlyingError {
                    self.log.error("\(underlyingError)")
                }

                self.stateMachine.notify(action: .errored(dataStoreError))
            } else {
                self.log.info("Successfully finished sync")

                self.remoteSyncTopicPublisher.send(.performedInitialSync)
                self.stateMachine.notify(action: .performedInitialSync)
            }
            semaphore.signal()
        }

        semaphore.wait()
        self.initialSyncOrchestrator = nil
    }

    private func activateCloudSubscriptions() {
        log.debug(#function)
        reconciliationQueue?.start()
    }

    private func startMutationQueue(api: APICategoryGraphQLBehavior,
                                    mutationEventPublisher: MutationEventPublisher) {
        log.debug(#function)
        outgoingMutationQueue.startSyncingToCloud(api: api,
                                                  mutationEventPublisher: mutationEventPublisher)

        remoteSyncTopicPublisher.send(.mutationQueueStarted)
        stateMachine.notify(action: .activatedMutationQueue)
    }

    private func cleanup(error: AmplifyError) {
        reconciliationQueue?.cancel()
        reconciliationQueue = nil
        outgoingMutationQueue.stopSyncingToCloud {
            self.remoteSyncTopicPublisher.send(.cleanedUp)
            self.stateMachine.notify(action: .cleanedUp(error))
        }
    }

    private func cleanupForTermination() {
        reconciliationQueue?.cancel()
        reconciliationQueue = nil
        outgoingMutationQueue.stopSyncingToCloud {
            self.mutationEventPublisher.cancel()
            self.remoteSyncTopicPublisher.send(.cleanedUpForTermination)
            self.stateMachine.notify(action: .cleanedUpForTermination)
        }
    }

    /// Must be invoked from workQueue (as in during a `respond` call
    private func notifySyncStarted() {
        resetCurrentAttemptNumber()
        Amplify.Hub.dispatch(to: .dataStore,
                             payload: HubPayload(eventName: HubPayload.EventName.DataStore.syncStarted))

        remoteSyncTopicPublisher.send(.syncStarted)
        stateMachine.notify(action: .notifiedSyncStarted)
    }

    private func onReceiveNetworkStatus(networkStatus: ReachabilityUpdate) {
        let networkStatusEvent = NetworkStatusEvent(active: networkStatus.isOnline)
        let networkStatusEventPayload = HubPayload(eventName: HubPayload.EventName.DataStore.networkStatus,
                                                   data: networkStatusEvent)
        Amplify.Hub.dispatch(to: .dataStore, payload: networkStatusEventPayload)
    }

    /// Must be invoked from workQueue (as during a `respond` call)
    func cancelEmitters() {
        syncEventEmitter = nil
        readyEventEmitter = nil
    }

    func reset(onComplete: () -> Void) {
        let group = DispatchGroup()

        group.enter()

        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if let resettable = child.value as? Resettable {
                DispatchQueue.global().async {
                    resettable.reset {
                        group.leave()
                    }
                }
            }
        }

        group.wait()
        onComplete()
    }
}

@available(iOS 13.0, *)
extension RemoteSyncEngine: DefaultLogger { }

@available(iOS 13.0, *)
extension RemoteSyncEngine: AuthModeStrategyDelegate {
    func isUserLoggedIn() -> Bool {
        // if OIDC is used as authentication provider
        // use `getLatestAuthToken`
        if let authProviderFactory = api as? APICategoryAuthProviderFactoryBehavior,
           let oidcAuthProvider = authProviderFactory.apiAuthProviderFactory().oidcAuthProvider() {
            switch oidcAuthProvider.getLatestAuthToken() {
            case .failure:
                return false
            case .success:
                return true
            }
        }

        return auth?.getCurrentUser() != nil
    }
}
