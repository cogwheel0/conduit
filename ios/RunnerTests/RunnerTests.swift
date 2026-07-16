import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testHermesFlutterAssetCanBeLoadedAsAnImage() {
    let image = loadFlutterAssetImage("assets/icons/hermes_agent.png")
    XCTAssertNotNil(image)
  }

  func testHermesAvatarCanUseTemplateRenderingInDarkMode() throws {
    let image = try XCTUnwrap(loadFlutterAssetImage("assets/icons/hermes_agent.png"))

    XCTAssertEqual(
      nativeAvatarImage(image, isTemplate: true).renderingMode,
      .alwaysTemplate
    )
    XCTAssertNotEqual(
      nativeAvatarImage(image, isTemplate: false).renderingMode,
      .alwaysTemplate
    )
  }

}
