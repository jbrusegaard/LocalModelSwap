import Foundation
import XCTest
@testable import ModelSwitchCore

final class ModelRowSortKeyTests: XCTestCase {
    private func row(
        id: String,
        state: ModelState = .unloaded,
        sizeBytes: Int64? = nil,
        context: String = "262144",
        manual: Bool = false
    ) -> ModelRow {
        let provider = ProviderConfiguration(
            name: "p", baseURL: "http://x:1", apiKey: "k",
            timeoutMs: "1000", defaultContextTokens: "262144"
        )
        return ModelRow(
            serverID: provider.id,
            serverName: provider.name,
            model: ServerModel(id: id, loaded: false, state: state, sizeBytes: sizeBytes, manual: manual),
            contextTokens: context
        )
    }

    func testStateRankOrdersBusyStatesFirst() {
        XCTAssertEqual(ModelState.ready.sortRank, 0)
        XCTAssertEqual(ModelState.loading.sortRank, 1)
        XCTAssertEqual(ModelState.error.sortRank, 2)
        XCTAssertEqual(ModelState.unloaded.sortRank, 3)
        XCTAssertEqual(ModelState.unknown.sortRank, 4)
    }

    func testMissingSizeSortsBeforeRealSizes() {
        let missing = row(id: "a").sizeForSort
        let tiny = row(id: "b", sizeBytes: 1).sizeForSort
        XCTAssertLessThan(missing, tiny)
    }

    func testNonNumericContextSortsBeforeNumericContext() {
        XCTAssertLessThan(row(id: "a", context: "oops").contextForSort,
                          row(id: "b", context: "0").contextForSort)
    }

    func testContextSortIsNumericNotLexicographic() {
        XCTAssertLessThan(row(id: "a", context: "9000").contextForSort,
                          row(id: "b", context: "10000").contextForSort)
    }

    func testServerSourceSortsBeforeManual() {
        XCTAssertEqual(row(id: "a").sourceForSort, 0)
        XCTAssertEqual(row(id: "b", manual: true).sourceForSort, 1)
    }
}
