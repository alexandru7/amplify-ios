//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import XCTest
import SQLite

@testable import Amplify
@testable import AmplifyTestCommon
@testable import AWSDataStoreCategoryPlugin
@testable import AWSPluginsCore

class RemoteSyncReconcilerTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: reconcile(pendingMutations)

    func testReconcilePendingMutations_EmptyRemoteModels() {
        let pendingMutations: [MutationEvent] = [makeMutationEvent()]
        let results = RemoteSyncReconciler.reconcile([], pendingMutations: pendingMutations)

        XCTAssertTrue(results.isEmpty)
    }

    func testReconcilePendingMutations_EmptyPendingMutations() {
        let remoteModel = makeRemoteModel()
        let results = RemoteSyncReconciler.reconcile([remoteModel], pendingMutations: [])

        XCTAssertEqual(results.first?.model.id, remoteModel.model.id)
    }

    func testReconcilePendingMutations_pendingMutationMatchRemoteModel() {
        let remoteModel = makeRemoteModel()
        let pendingMutation = makeMutationEvent(modelId: remoteModel.model.id)
        let results = RemoteSyncReconciler.reconcile([remoteModel], pendingMutations: [pendingMutation])

        XCTAssertTrue(results.isEmpty)
    }

    func testReconcilePendingMutations_pendingMutationDoesNotMatchRemoteModel() {
        let remoteModel = makeRemoteModel(modelId: "1")
        let pendingMutation = makeMutationEvent(modelId: "2")
        let results = RemoteSyncReconciler.reconcile([remoteModel], pendingMutations: [pendingMutation])

        XCTAssertEqual(results.first?.model.id, remoteModel.model.id)
    }

    // MARK: - reconcile(remoteModel:localMetadata)

    func testReconcileLocalMetadata_nilLocalMetadata() {
        let remoteModel = makeRemoteModel(deleted: false, version: 1)

        let disposition = RemoteSyncReconciler.reconcile(remoteModel,
                                                          localMetadata: nil)

        XCTAssertEqual(disposition, .create(remoteModel))
    }

    func testReconcileLocalMetadata_nilLocalMetadata_deletedModel() {
        let remoteModel = makeRemoteModel(deleted: true, version: 2)

        let disposition = RemoteSyncReconciler.reconcile(remoteModel,
                                                          localMetadata: nil)

        XCTAssertNil(disposition)
    }

    func testReconcileLocalMetadata_withLocalEqualVersion() {
        let remoteModel = makeRemoteModel(deleted: false, version: 1)
        let localSyncMetadata = makeMutationSyncMetadata(modelId: remoteModel.model.id,
                                                         deleted: false,
                                                         version: 1)

        let disposition = RemoteSyncReconciler.reconcile(remoteModel,
                                                         localMetadata: localSyncMetadata)

        XCTAssertEqual(disposition, .update(remoteModel))
    }

    func testReconcileLocalMetadata_withLocalLowerVersion() {
        let remoteModel = makeRemoteModel(deleted: false, version: 2)
        let localSyncMetadata = makeMutationSyncMetadata(modelId: remoteModel.model.id,
                                                         deleted: false,
                                                         version: 1)

        let disposition = RemoteSyncReconciler.reconcile(remoteModel,
                                                         localMetadata: localSyncMetadata)

        XCTAssertEqual(disposition, .update(remoteModel))
    }

    func testReconcileLocalMetadata_withLocalLowerVersion_deletedModel() {
        let remoteModel = makeRemoteModel(deleted: true, version: 2)
        let localSyncMetadata = makeMutationSyncMetadata(modelId: remoteModel.model.id,
                                                         deleted: false,
                                                         version: 1)

        let disposition = RemoteSyncReconciler.reconcile(remoteModel,
                                                         localMetadata: localSyncMetadata)

        XCTAssertEqual(disposition, .delete(remoteModel))
    }

    func testReconcileLocalMetadata_withLocalHigherVersion() {
        let remoteModel = makeRemoteModel(deleted: false, version: 1)
        let localSyncMetadata = makeMutationSyncMetadata(modelId: remoteModel.model.id,
                                                         deleted: false,
                                                         version: 2)

        let disposition = RemoteSyncReconciler.reconcile(remoteModel,
                                                         localMetadata: localSyncMetadata)

        XCTAssertNil(disposition)
    }

    // This shouldn't be possible except in case of an error (either the service side did not properly resolve a
    // conflict updating a deleted record, or the client is incorrectly manipulating the version
    func testReconcileLocalMetadata_withLocalHigherVersion_deletedModel() {
        let remoteModel = makeRemoteModel(deleted: true, version: 1)
        let localSyncMetadata = makeMutationSyncMetadata(modelId: remoteModel.model.id,
                                                         deleted: false,
                                                         version: 2)

        let disposition = RemoteSyncReconciler.reconcile(remoteModel,
                                                         localMetadata: localSyncMetadata)

        XCTAssertNil(disposition)
    }

    // MARK: - reconcile(remoteModels:localMetadatas)

    func testReconcileLocalMetadatas_emptyRemoteModel() {
        let localSyncMetadata = makeMutationSyncMetadata(modelId: "1", deleted: false, version: 1)

        let dispositions = RemoteSyncReconciler.reconcile([], localMetadatas: [localSyncMetadata])

        XCTAssertTrue(dispositions.isEmpty)
    }

    func testReconcileLocalMetadatas_emptyLocal() {
        let remoteModel = makeRemoteModel(deleted: false, version: 1)

        let dispositions = RemoteSyncReconciler.reconcile([remoteModel], localMetadatas: [])

        XCTAssertEqual(dispositions.first, .create(remoteModel))
    }

    func testReconcileLocalMetadatas_emptyLocal_deletedModel() {
        let remoteModel = makeRemoteModel(deleted: true, version: 2)

        let dispositions = RemoteSyncReconciler.reconcile([remoteModel], localMetadatas: [])

        XCTAssertTrue(dispositions.isEmpty)
    }

    func testReconcileLocalMetadatas_multiple() {
        // no corresponding local metadata, not deleted remote, should be create
        let createModel = makeRemoteModel(deleted: false, version: 1)

        // no corresponding local metadata, deleted remote, should be dropped
        let droppedModel = makeRemoteModel(deleted: true, version: 2)

        // with local metadata, not deleted remote, should be update
        let updateModel = makeRemoteModel(deleted: false, version: 2)
        let localUpdateMetadata = makeMutationSyncMetadata(modelId: updateModel.model.id,
                                                         deleted: false,
                                                         version: 1)

        // with local metadata, deleted remote, should be delete
        let deleteModel = makeRemoteModel(deleted: true, version: 2)
        let localDeleteMetadata = makeMutationSyncMetadata(modelId: deleteModel.model.id,
                                                         deleted: false,
                                                         version: 1)

        let remoteModels = [createModel, droppedModel, updateModel, deleteModel]
        let localMetadatas = [localUpdateMetadata, localDeleteMetadata]
        let dispositions = RemoteSyncReconciler.reconcile(remoteModels,
                                                         localMetadatas: localMetadatas)

        XCTAssertEqual(dispositions.count, 3)
        let create = expectation(description: "exactly one create")
        let update = expectation(description: "exactly one update")
        let delete = expectation(description: "exactly one delete")
        for disposition in dispositions {
            switch disposition {
            case .create(let remoteModel):
                XCTAssertEqual(remoteModel.model.id, createModel.model.id)
                create.fulfill()
            case .update(let remoteModel):
                XCTAssertEqual(remoteModel.model.id, updateModel.model.id)
                update.fulfill()
            case .delete(let remoteModel):
                XCTAssertEqual(remoteModel.model.id, deleteModel.model.id)
                delete.fulfill()
            }
        }
        waitForExpectations(timeout: 1)
    }

    // MARK: - Utilities

    private func makeMutationSyncMetadata(modelId: String,
                                          deleted: Bool = false,
                                          version: Int = 1) -> MutationSyncMetadata {

        let remoteSyncMetadata = MutationSyncMetadata(id: modelId,
                                                      deleted: deleted,
                                                      lastChangedAt: Date().unixSeconds,
                                                      version: version)
        return remoteSyncMetadata
    }

    private func makeRemoteModel(modelId: String = UUID().uuidString,
                                 deleted: Bool = false,
                                 version: Int = 1) -> ReconcileAndLocalSaveOperation.RemoteModel {
        do {
            let remoteMockSynced = try MockSynced(id: modelId).eraseToAnyModel()
            let remoteSyncMetadata = makeMutationSyncMetadata(modelId: remoteMockSynced.id,
                                                              deleted: deleted,
                                                              version: version)
            return ReconcileAndLocalSaveOperation.RemoteModel(model: remoteMockSynced,
                                                              syncMetadata: remoteSyncMetadata)
        } catch {
            fatalError("Failed to create remote model")
        }
    }

    private func makeMutationEvent(modelId: String = UUID().uuidString) -> MutationEvent {
        return MutationEvent(id: "mutation-1",
                             modelId: modelId,
                             modelName: MockSynced.modelName,
                             json: "{}",
                             mutationType: .create,
                             createdAt: .now(),
                             version: 1,
                             inProcess: false)
    }

}
