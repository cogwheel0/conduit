//
//  NotificationDelegate.swift
//  Pods
//
//  Created by Hien Nguyen on 2/8/25.
//

import Foundation
import UIKit
import UserNotifications

public class CallkitNotificationManager: NSObject {
    
    public static let MISSED_CALL_CATEGORY = "MISSED_CALL_CATEGORY"
    
    public static let CALLBACK_ACTION = "CALLBACK_ACTION"
    
    public static let shared = CallkitNotificationManager()
    
    private var dataNotificationPermission: [String: Any] = [:]
    
    private override init() {
        super.init()
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound, .badge])
    }
    
    public func addNotificationCategory(_ nameCallbackAction: String) {
        let callbackAction = UNNotificationAction(identifier: CallkitNotificationManager.CALLBACK_ACTION,
                                                  title: nameCallbackAction,
                                                  options: [.foreground])
        
        let missedCallCategory = UNNotificationCategory(identifier: CallkitNotificationManager.MISSED_CALL_CATEGORY,
                                                        actions: [callbackAction],
                                                        intentIdentifiers: [],
                                                        options: [])
        
        UNUserNotificationCenter.current().getNotificationCategories { categories in
            var updatedCategories = categories
            updatedCategories.insert(missedCallCategory)
            UNUserNotificationCenter.current().setNotificationCategories(updatedCategories)
        }
    }
    
    
    public func requestNotificationPermission(_ map: [String: Any]){
        self.dataNotificationPermission = map
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: self.dataNotificationPermission["title"] as? String ?? "Notification Permission",
                                                  message: self.dataNotificationPermission["rationaleMessagePermission"] as? String ?? "Notification permission is required, to show notification.",
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    alert.addAction(UIAlertAction(title: "Ok", style: .default) { _ in
                        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                            if let error = error {
                                print("Notification permission error: \(error)")
                            } else {
                                print("Permission granted: \(granted)")
                            }
                        }
                    })
                    UIApplication.shared.keyWindow?.rootViewController?.present(alert, animated: true)
                }
                
            case .denied:
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: self.dataNotificationPermission["title"] as? String ?? "Notification Permission",
                                                  message: self.dataNotificationPermission["postNotificationMessageRequired"] as? String ?? "Notification permission is required, Please allow notification permission from setting.",
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    alert.addAction(UIAlertAction(title: "Ok", style: .default) { _ in
                        if let settingsUrl = URL(string: UIApplication.openSettingsURLString),
                           UIApplication.shared.canOpenURL(settingsUrl) {
                            UIApplication.shared.open(settingsUrl)
                        }
                    })
                    UIApplication.shared.keyWindow?.rootViewController?.present(alert, animated: true)
                }
                
            case .authorized, .provisional, .ephemeral:
                print("Notification permission is already granted.")
            @unknown default:
                print("Unknown notification permission state.")
            }
        }
    }
    
    
    
    
    
    
    
}
