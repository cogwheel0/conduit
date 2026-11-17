// The widget extension's entry point (only the .appex builds this file;
// the render tool has its own).

import SwiftUI
import WidgetKit

@main
struct ConduitWidgetBundle: WidgetBundle {
    var body: some Widget {
        ConduitWidget()
    }
}
