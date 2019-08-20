import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(FrontendTests.allTests),
        testCase(AnalysisTests.allTests),
        testCase(SolverTests.allTests),
        testCase(IntegrationTests.allTests),
    ]
}
#endif
