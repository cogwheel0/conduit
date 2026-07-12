import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testHermesFlutterAssetCanBeLoadedAsAnImage() {
    let image = loadFlutterAssetImage("assets/icons/hermes_agent.png")
    XCTAssertNotNil(image)
  }

}
