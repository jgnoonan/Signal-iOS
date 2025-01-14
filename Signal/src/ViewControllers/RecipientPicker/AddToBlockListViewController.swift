//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol AddToBlockListDelegate: AnyObject {
    func addToBlockListComplete()
}

class AddToBlockListViewController: RecipientPickerContainerViewController {

    weak var delegate: AddToBlockListDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("SETTINGS_ADD_TO_BLOCK_LIST_TITLE",
                                  comment: "Title for the 'add to block list' view.")

        recipientPicker.selectionMode = .blocklist
        recipientPicker.groupsToShow = .allGroupsWhenSearching
        recipientPicker.findByPhoneNumberButtonTitle = OWSLocalizedString(
            "BLOCK_LIST_VIEW_BLOCK_BUTTON",
            comment: "A label for the block button in the block list view"
        )
        recipientPicker.delegate = self
        addChild(recipientPicker)
        view.addSubview(recipientPicker.view)
        recipientPicker.view.autoPin(toTopLayoutGuideOf: self, withInset: 0)
        recipientPicker.view.autoPinEdge(toSuperviewEdge: .leading)
        recipientPicker.view.autoPinEdge(toSuperviewEdge: .trailing)
        recipientPicker.view.autoPinEdge(toSuperviewEdge: .bottom)
    }

    func block(address: SignalServiceAddress) {
        BlockListUIUtils.showBlockAddressActionSheet(address, from: self) { [weak self] isBlocked in
            guard isBlocked else { return }
            self?.delegate?.addToBlockListComplete()
        }
    }

    func block(thread: TSThread) {
        BlockListUIUtils.showBlockThreadActionSheet(thread, from: self) { [weak self] isBlocked in
            guard isBlocked else { return }
            self?.delegate?.addToBlockListComplete()
        }
    }
}

extension AddToBlockListViewController: RecipientPickerDelegate, UsernameLinkScanDelegate {

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        getRecipientState recipient: PickedRecipient
    ) -> RecipientPickerRecipientState {
        switch recipient.identifier {
        case .address(let address):
            let isAddressBlocked = SSKEnvironment.shared.databaseStorageRef.read { SSKEnvironment.shared.blockingManagerRef.isAddressBlocked(address, transaction: $0) }
            guard !isAddressBlocked else {
                return .userAlreadyInBlocklist
            }
            return .canBeSelected
        case .group(let thread):
            let isThreadBlocked = SSKEnvironment.shared.databaseStorageRef.read { SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: $0) }
            guard !isThreadBlocked else {
                return .conversationAlreadyInBlocklist
            }
            return .canBeSelected
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        didSelectRecipient recipient: PickedRecipient
    ) {
        switch recipient.identifier {
        case .address(let address):
            block(address: address)
        case .group(let groupThread):
            block(thread: groupThread)
        }
    }

    func recipientPicker(
        _ recipientPickerViewController: RecipientPickerViewController,
        accessoryMessageForRecipient recipient: PickedRecipient,
        transaction: SDSAnyReadTransaction
    ) -> String? {
        switch recipient.identifier {
        case .address(let address):
            #if DEBUG
            let isBlocked = SSKEnvironment.shared.blockingManagerRef.isAddressBlocked(address, transaction: transaction)
            owsPrecondition(!isBlocked, "It should be impossible to see a blocked connection in this view")
            #endif
            return nil
        case .group(let thread):
            guard SSKEnvironment.shared.blockingManagerRef.isThreadBlocked(thread, transaction: transaction) else { return nil }
            return MessageStrings.conversationIsBlocked
        }
    }
}
