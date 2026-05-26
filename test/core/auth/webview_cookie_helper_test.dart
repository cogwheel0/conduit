import 'package:conduit/core/auth/webview_cookie_helper.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('apple website data clear set targets storage without cookies', () {
    expect(
      appleWebsiteDataTypesForTesting,
      containsAll(<WebsiteDataType>{
        WebsiteDataType.WKWebsiteDataTypeLocalStorage,
        WebsiteDataType.WKWebsiteDataTypeSessionStorage,
        WebsiteDataType.WKWebsiteDataTypeIndexedDBDatabases,
        WebsiteDataType.WKWebsiteDataTypeWebSQLDatabases,
        WebsiteDataType.WKWebsiteDataTypeOfflineWebApplicationCache,
        WebsiteDataType.WKWebsiteDataTypeFetchCache,
        WebsiteDataType.WKWebsiteDataTypeServiceWorkerRegistrations,
      }),
    );
    expect(
      appleWebsiteDataTypesForTesting,
      isNot(contains(WebsiteDataType.WKWebsiteDataTypeCookies)),
    );
  });
}
