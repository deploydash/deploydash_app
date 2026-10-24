import Cocoa
import XCTest

private final class FakeSemanticsEngine: NSObject {
  @objc dynamic var semanticsEnabled = false
}

class SemanticsEnablerTests: XCTestCase {

  func testEnablesSemanticsThroughKeyValueCoding() {
    let engine = FakeSemanticsEngine()
    deploydash_enableSemantics(engine)
    XCTAssertTrue(engine.semanticsEnabled)
  }

  func testIgnoresEnginesWithoutTheSetter() {
    // Must not raise: the guard is the fallback when a future Flutter
    // renames or removes the internal setter.
    deploydash_enableSemantics(NSObject())
  }

}
