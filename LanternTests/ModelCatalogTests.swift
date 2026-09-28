import Foundation
import Testing
@testable import Lantern

struct ModelCatalogTests {
    @Test func idsAreUniqueAndLookUp() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ModelCatalog.entry(id: ModelCatalog.defaultEntry.id) == ModelCatalog.defaultEntry)
        #expect(ModelCatalog.entry(id: "nope/nothing") == nil)
    }

    @Test func defaultIsTheSmallestSafeModel() {
        #expect(ModelCatalog.defaultEntry.requiredTier == .compact)
        #expect(ModelCatalog.defaultEntry.comfortableTier == .compact)
        #expect(ModelCatalog.defaultEntry.parameterBillions < 1.5)
        #expect(ModelCatalog.defaultEntry.gated == false)
    }

    @Test func nothingAboveEightBillion() {
        for entry in ModelCatalog.all {
            #expect(entry.parameterBillions <= ModelCatalog.maximumParameterBillions, "\(entry.id)")
        }
    }

    @Test func tierFilteringHidesProModelsFromStandard() {
        let standard = ModelCatalog.entries(for: .standard)
        #expect(!standard.contains(ModelCatalog.llama3_1_8B))
        #expect(standard.contains(ModelCatalog.llama3_2_3B))
        #expect(ModelCatalog.entries(for: .unsupported).isEmpty)
        #expect(ModelCatalog.entries(for: .compact) == [ModelCatalog.llama3_2_1B, ModelCatalog.qwen2_5_1_5B, ModelCatalog.smolVLM500M])
        #expect(ModelCatalog.entries(for: .pro).count == ModelCatalog.all.count)
    }

    @Test func folderNamesHaveNoSlashes() {
        for entry in ModelCatalog.all {
            #expect(!entry.folderName.contains("/"))
        }
    }

    @Test func visionModelsAreMarkedAndFitTheirTiers() {
        #expect(ModelCatalog.vision.map(\.id) == [ModelCatalog.smolVLM500M.id, ModelCatalog.qwen2VL2B.id])
        let allSee = ModelCatalog.vision.allSatisfy { $0.seesPhotos }
        #expect(allSee)
        #expect(ModelCatalog.llama3_2_1B.seesPhotos == false)
        #expect(ModelCatalog.smolVLM500M.requiredTier == .compact)
        #expect(ModelCatalog.qwen2VL2B.requiredTier == .standard)
        #expect(ModelCatalog.entries(for: .compact).contains(ModelCatalog.smolVLM500M))
    }
}
