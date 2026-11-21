//
//  NSUserActivity.swift
//  Runner
//
//  Created by Hien Nguyen on 20/02/2022.
//

import Foundation
import Intents

extension NSUserActivity: StartCallConvertible {

    public var handle: String? {
        guard
          let interaction = interaction,
          let startCallIntent = interaction.intent as? SupportedStartCallIntent,
          let contact = startCallIntent.contacts?.first
        else {
            return nil
        }
        print(interaction.intent)
        return contact.personHandle?.value
    }

    public var isVideo: Bool? {
        guard
          let interaction = interaction,
          let startCallIntent = interaction.intent as? SupportedStartCallIntent
        else {
            return nil
        }

        return startCallIntent is INStartVideoCallIntent
    }
    
}


protocol StartCallConvertible {
    var handle: String? { get }
    var isVideo: Bool? { get }
}

extension StartCallConvertible {

    var isVideo: Bool? {
        return nil
    }

}


protocol SupportedStartCallIntent {
    var contacts: [INPerson]? { get }
}

extension INStartAudioCallIntent: SupportedStartCallIntent {}
extension INStartVideoCallIntent: SupportedStartCallIntent {}
