//
//  ConduitWidgetBundle.swift
//  ConduitWidget
//
//  Created by cogwheel on 07/12/25.
//

import WidgetKit
import SwiftUI

@main
struct ConduitWidgetBundle: WidgetBundle {
    var body: some Widget {
        ConduitWidget()
        if #available(iOS 17.0, *) { ConduitRecordingActivity() }
    }
}
