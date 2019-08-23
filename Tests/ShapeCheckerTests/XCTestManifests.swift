import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(FrontendTests.allTests),
        testCase(AnalysisTests.allTests),
        testCase(IntegrationTests.allTests),
        testCase(Z3Tests.allTests),
    ]
}
#endif
