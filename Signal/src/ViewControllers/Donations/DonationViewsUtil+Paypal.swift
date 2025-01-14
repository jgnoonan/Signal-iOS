//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

extension DonationViewsUtil {
    enum Paypal {
        /// Create a PayPal payment, returning a PayPal URL to present to the user
        /// for authentication. Presents an activity indicator while in-progress.
        static func createPaypalPaymentBehindActivityIndicator(
            amount: FiatMoney,
            level: OneTimeBadgeLevel,
            fromViewController: UIViewController
        ) -> Promise<(URL, String)> {
            let (promise, future) = Promise<(URL, String)>.pending()

            ModalActivityIndicatorViewController.present(
                fromViewController: fromViewController,
                canCancel: false
            ) { modal in
                firstly {
                    SignalServiceKit.Paypal.createBoost(amount: amount, level: level)
                }.map(on: DispatchQueue.main) { approvalUrl in
                    modal.dismiss { future.resolve(approvalUrl) }
                }.catch(on: DispatchQueue.main) { error in
                    modal.dismiss { future.reject(error) }
                }
            }

            return promise
        }
    }
}
