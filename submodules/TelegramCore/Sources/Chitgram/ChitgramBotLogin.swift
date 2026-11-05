import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit

public enum ChitgramBotLoginError {
    /// The server refused the token (`ACCESS_TOKEN_INVALID` and the like).
    case invalidToken
    /// Too many attempts; the number of seconds to wait, when the server said.
    case floodWait(Int32?)
    case generic
}

/// A BotFather token: `<bot user id>:<secret>` (Android `BotLoginController.TOKEN_REGEX`).
public func chitgramIsValidBotToken(_ token: String) -> Bool {
    let parts = token.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let id = parts.first, !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        return false
    }
    let secret = parts[1]
    return secret.count >= 30 && secret.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
}

/// Logs in as a bot with its BotFather token (Android `BotLoginController`, `auth.importBotAuthorization`), the same way
/// a phone login finishes: the account becomes the bot's, after moving to the bot's datacenter when the server asks.
public func chitgramAuthorizeWithBotToken(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, token: String, syncContacts: Bool) -> Signal<Void, ChitgramBotLoginError> {
    let request = Api.functions.auth.importBotAuthorization(flags: 0, apiId: account.networkArguments.apiId, apiHash: account.networkArguments.apiHash, botAuthToken: token)
    let authorizationAndAccount = account.network.request(request, automaticFloodWait: false)
    |> map { result -> (Api.auth.Authorization, UnauthorizedAccount) in
        return (result, account)
    }
    |> `catch` { error -> Signal<(Api.auth.Authorization, UnauthorizedAccount), MTRpcError> in
        let description = error.errorDescription ?? ""
        guard let range = description.range(of: "_MIGRATE_"), let datacenterId = Int32(description[range.upperBound...]) else {
            return .fail(error)
        }
        return account.changedMasterDatacenterId(accountManager: accountManager, masterDatacenterId: datacenterId)
        |> castError(MTRpcError.self)
        |> mapToSignal { updatedAccount -> Signal<(Api.auth.Authorization, UnauthorizedAccount), MTRpcError> in
            return updatedAccount.network.request(request, automaticFloodWait: false)
            |> map { result -> (Api.auth.Authorization, UnauthorizedAccount) in
                return (result, updatedAccount)
            }
        }
    }
    |> mapError { error -> ChitgramBotLoginError in
        let description = error.errorDescription ?? ""
        if description.hasPrefix("FLOOD_WAIT") {
            return .floodWait(description.components(separatedBy: "_").last.flatMap { Int32($0) })
        } else if description.contains("TOKEN") || description.contains("BOT") {
            return .invalidToken
        } else {
            return .generic
        }
    }

    return authorizationAndAccount
    |> mapToSignal { result, account -> Signal<Void, ChitgramBotLoginError> in
        return account.postbox.transaction { transaction -> Signal<Void, NoError> in
            switch result {
            case let .authorization(authorizationData):
                let user = TelegramUser(user: authorizationData.user)
                let state = AuthorizedAccountState(isTestingEnvironment: account.testingEnvironment, masterDatacenterId: account.masterDatacenterId, peerId: user.id, state: nil, invalidatedChannels: [])
                initializedAppSettingsAfterLogin(transaction: transaction, appVersion: account.networkArguments.appVersion, syncContacts: syncContacts)
                transaction.setState(state)
                return accountManager.transaction { transaction -> Void in
                    switchToAuthorizedAccount(transaction: transaction, account: account, isSupportUser: false)
                }
            case .authorizationSignUpRequired:
                return .complete()
            }
        }
        |> switchToLatest
        |> castError(ChitgramBotLoginError.self)
    }
}
