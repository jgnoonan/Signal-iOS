//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalUI

private enum OpenableUrl {
    case phoneNumberLink(URL)
    case usernameLink(Usernames.UsernameLink)
    case stickerPack(StickerPackInfo)
    case groupInvite(URL)
    case signalProxy(URL)
    case linkDevice(DeviceProvisioningURL)
    case completeIDEALDonation(Stripe.IDEALCallbackType)
    case callLink(CallLink)
}

class UrlOpener {
    private let appReadiness: AppReadinessSetter
    private let databaseStorage: SDSDatabaseStorage
    private let tsAccountManager: TSAccountManager

    init(
        appReadiness: AppReadinessSetter,
        databaseStorage: SDSDatabaseStorage,
        tsAccountManager: TSAccountManager
    ) {
        self.appReadiness = appReadiness
        self.databaseStorage = databaseStorage
        self.tsAccountManager = tsAccountManager
    }

    // MARK: - Constants

    enum Constants {
        static let sgnlPrefix = "sgnl"
    }

    // MARK: - Parsing URLs

    struct ParsedUrl {
        fileprivate let openableUrl: OpenableUrl
    }

    static func parseUrl(_ url: URL) -> ParsedUrl? {
        guard let openableUrl = parseOpenableUrl(url) else {
            return nil
        }
        return ParsedUrl(openableUrl: openableUrl)
    }

    private static func parseOpenableUrl(_ url: URL) -> OpenableUrl? {
        if SignalDotMePhoneNumberLink.isPossibleUrl(url) {
            return .phoneNumberLink(url)
        }
        if let usernameLink = Usernames.UsernameLink(usernameLinkUrl: url) {
            return .usernameLink(usernameLink)
        }
        if StickerPackInfo.isStickerPackShare(url), let stickerPackInfo = StickerPackInfo.parseStickerPackShare(url) {
            return .stickerPack(stickerPackInfo)
        }
        if let stickerPackInfo = parseSgnlAddStickersUrl(url) {
            return .stickerPack(stickerPackInfo)
        }
        if GroupManager.isPossibleGroupInviteLink(url) {
            return .groupInvite(url)
        }
        if SignalProxy.isValidProxyLink(url) {
            return .signalProxy(url)
        }
        if let deviceProvisioningUrl = parseSgnlLinkDeviceUrl(url) {
            return .linkDevice(deviceProvisioningUrl)
        }
        if let donationType = Stripe.parseStripeIDEALCallback(url) {
            return .completeIDEALDonation(donationType)
        }
        if let callLink = CallLink(url: url) {
            return .callLink(callLink)
        }
        owsFailDebug("Couldn't parse URL")
        return nil
    }

    private static func parseSgnlAddStickersUrl(_ url: URL) -> StickerPackInfo? {
        guard
            let components = URLComponents(string: url.absoluteString),
            components.scheme == Constants.sgnlPrefix,
            components.host?.hasPrefix("addstickers") == true,
            let queryItems = components.queryItems
        else {
            return nil
        }
        var packIdHex: String?
        var packKeyHex: String?
        for queryItem in queryItems {
            switch queryItem.name {
            case "pack_id":
                owsAssertDebug(packIdHex == nil)
                packIdHex = queryItem.value
            case "pack_key":
                owsAssertDebug(packKeyHex == nil)
                packKeyHex = queryItem.value
            default:
                Logger.warn("Unknown query item in sticker pack url")
            }
        }
        return StickerPackInfo.parse(packIdHex: packIdHex, packKeyHex: packKeyHex)
    }

    private static func parseSgnlLinkDeviceUrl(_ url: URL) -> DeviceProvisioningURL? {
        guard url.scheme == Constants.sgnlPrefix, url.host?.hasPrefix(DeviceProvisioningURL.Constants.linkDeviceHost) == true else {
            return nil
        }
        return DeviceProvisioningURL(urlString: url.absoluteString)
    }

    // MARK: - Opening URLs

    func openUrl(_ parsedUrl: ParsedUrl, in window: UIWindow) {
        guard tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            return owsFailDebug("Ignoring URL; not registered.")
        }
        guard let rootViewController = window.rootViewController else {
            return owsFailDebug("Ignoring URL; no root view controller.")
        }
        if shouldDismiss(for: parsedUrl.openableUrl) && rootViewController.presentedViewController != nil {
            rootViewController.dismiss(animated: false, completion: {
                self.openUrlAfterDismissing(parsedUrl.openableUrl, rootViewController: rootViewController)
            })
        } else {
            openUrlAfterDismissing(parsedUrl.openableUrl, rootViewController: rootViewController)
        }
    }

    private func shouldDismiss(for url: OpenableUrl) -> Bool {
        switch url {
        case .completeIDEALDonation: return false
        case .groupInvite, .linkDevice, .phoneNumberLink, .signalProxy, .stickerPack, .usernameLink, .callLink: return true
        }
    }

    private func openUrlAfterDismissing(_ openableUrl: OpenableUrl, rootViewController: UIViewController) {
        switch openableUrl {
        case .phoneNumberLink(let url):
            SignalDotMePhoneNumberLink.openChat(url: url, fromViewController: rootViewController)

        case .usernameLink(let link):
            databaseStorage.read { tx in
                UsernameQuerier().queryForUsernameLink(
                    link: link,
                    fromViewController: rootViewController,
                    tx: tx
                ) { _, aci in
                    SignalApp.shared.presentConversationForAddress(
                        SignalServiceAddress(aci),
                        animated: true
                    )
                }
            }

        case .stickerPack(let stickerPackInfo):
            let stickerPackViewController = StickerPackViewController(stickerPackInfo: stickerPackInfo)
            stickerPackViewController.present(from: rootViewController, animated: false)

        case .groupInvite(let url):
            GroupInviteLinksUI.openGroupInviteLink(url, fromViewController: rootViewController)

        case .signalProxy(let url):
            rootViewController.present(ProxyLinkSheetViewController(url: url)!, animated: true)

        case .linkDevice(let provisioningUrl):
            guard tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegisteredPrimaryDevice else {
                owsFailDebug("Ignoring URL; not primary device.")
                return
            }

            SignalApp.shared.showAppSettings(mode: .linkNewDevice(provisioningUrl: provisioningUrl))

        case .completeIDEALDonation(let donationType):
            DonationViewsUtil.attemptToContinueActiveIDEALDonation(
                type: donationType,
                databaseStorage: self.databaseStorage
            )
            .then(on: DispatchQueue.main) { [weak self] handled -> Promise<Void> in
                guard let self else { return .value(()) }
                if handled {
                    return Promise.value(())
                }
                return DonationViewsUtil.restartAndCompleteInterruptedIDEALDonation(
                    type: donationType,
                    rootViewController: rootViewController,
                    databaseStorage: self.databaseStorage,
                    appReadiness: appReadiness
                )
            }.done {
                Logger.info("[Donations] Completed iDEAL donation")
            } .catch { error in
                switch error {
                case Signal.DonationJobError.timeout:
                    // This is an expected error case for pending donations
                    break
                default:
                    // Unexpected. Log a warning
                    Logger.warn("[Donations] Unexpected error encountered with iDEAL donation")
                }
            }

        case .callLink(let callLink):
            GroupCallViewController.presentLobby(for: callLink)
        }
    }
}