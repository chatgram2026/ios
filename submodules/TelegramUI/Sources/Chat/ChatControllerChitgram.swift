import Foundation
import UIKit
import Display
import AccountContext
import AlertUI
import PresentationDataUtils
import ChitgramCore

// Chitgram: the chat screen's own additions, kept out of the upstream files except for one-line hooks.
extension ChatControllerImpl {
    /// Android `ConfirmDialog`: "Chitgram" over "Do you really want to send?" with OK and Cancel. `completion`
    /// runs on OK; the caller re-enters its own send with `chitgramSendConfirmed` set so it does not ask twice.
    func chitgramConfirmSend(completion: @escaping () -> Void) {
        let strings = self.presentationInterfaceState.strings
        self.present(textAlertController(context: self.context, title: "Chitgram", text: ChitgramStrings.get(195), actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: completion)
        ]), in: .window(.root))
    }
}
