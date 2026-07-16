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

  func testTemplateAvatarHidesFallbackInitials() throws {
    let image = try XCTUnwrap(loadFlutterAssetImage("assets/icons/hermes_agent.png"))
    let imageView = UIImageView()
    let initialsLabel = UILabel()
    imageView.isHidden = true
    initialsLabel.isHidden = false

    applyNativeAvatarImage(
      image,
      isTemplate: true,
      to: imageView,
      initialsLabel: initialsLabel
    )

    XCTAssertFalse(imageView.isHidden)
    XCTAssertTrue(initialsLabel.isHidden)
    XCTAssertEqual(imageView.image?.renderingMode, .alwaysTemplate)
    XCTAssertEqual(imageView.contentMode, .scaleAspectFit)
  }

}
