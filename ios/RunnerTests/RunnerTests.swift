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

  func testNativeSheetImageCacheKeyScopesAuthenticatedImagesByHeaders() {
    let rawUrl = "https://example.test/avatar.png"
    let accountA = nativeSheetImageCacheKey(
      rawUrl: rawUrl,
      headers: ["Authorization": "Bearer account-a", "Accept": "image/png"]
    )
    let accountAReordered = nativeSheetImageCacheKey(
      rawUrl: rawUrl,
      headers: ["accept": "image/png", "authorization": "Bearer account-a"]
    )
    let accountB = nativeSheetImageCacheKey(
      rawUrl: rawUrl,
      headers: ["Authorization": "Bearer account-b", "Accept": "image/png"]
    )

    XCTAssertEqual(accountA, accountAReordered)
    XCTAssertNotEqual(accountA, accountB)
    XCTAssertFalse(String(accountA).contains("account-a"))
    XCTAssertEqual(
      nativeSheetImageCacheKey(rawUrl: rawUrl, headers: [:]),
      NSString(string: rawUrl)
    )
  }

}
