import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(FrontendTests.allTests),
        testCase(AnalysisTests.allTests),
    ]
}
#endif
