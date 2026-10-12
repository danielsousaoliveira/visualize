import Foundation
import Observation
import Testing
import os
@testable import visualize

@MainActor
struct SceneObservationTests {
    @Test func portChangesInvalidateLabelWithoutInvalidatingScenes() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let state = AppState(store: ProjectLibraryStore(directory: directory))
        state.listenerStore.stop()
        let sceneInvalidated = OSAllocatedUnfairLock(initialState: false)
        let labelInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = VisualizeScenes(appState: state).body
        } onChange: {
            sceneInvalidated.withLock { $0 = true }
        }
        withObservationTracking {
            _ = MenuBarLabel(listenerStore: state.listenerStore).body
        } onChange: {
            labelInvalidated.withLock { $0 = true }
        }
        state.listenerStore.configure(interval: 1, lower: 1024, upper: 65535, showCodingAgents: true)
        #expect(labelInvalidated.withLock { $0 })
        #expect(!sceneInvalidated.withLock { $0 })
    }

    @Test func backgroundAppChangesDoNotInvalidateScenes() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let state = AppState(store: ProjectLibraryStore(directory: directory))
        state.listenerStore.stop()
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = VisualizeScenes(appState: state).body
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        state.selection = UUID()
        state.libraryError = "Changed"
        state.listenerStore.configure(interval: 1, lower: 1024, upper: 65535, showCodingAgents: true)
        #expect(!invalidated.withLock { $0 })
    }
}
