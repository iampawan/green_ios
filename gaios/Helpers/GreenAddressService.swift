import Foundation
import UIKit
import PromiseKit

enum EventType: String {
    case Block = "block"
    case Transaction = "transaction"
    case TwoFactorReset = "twofactor_reset"
    case Settings = "settings"
    case AddressChanged = "address_changed"
    case Network = "network"
    case SystemMessage = "system_message"
    case Tor = "tor"
    case AssetsUpdated = "assets_updated"
    case Session = "session"
}

struct Connection: Codable {
    enum CodingKeys: String, CodingKey {
        case connected = "connected"
        case loginRequired = "login_required"
        case heartbeatTimeout = "heartbeat_timeout"
        case elapsed = "elapsed"
        case waiting = "waiting"
        case limit = "limit"
    }
    let connected: Bool
    let loginRequired: Bool?
    let heartbeatTimeout: Bool?
    let elapsed: Int?
    let waiting: Int?
    let limit: Bool?
}

struct Tor: Codable {
    enum CodingKeys: String, CodingKey {
        case tag
        case summary
        case progress
    }
    let tag: String
    let summary: String
    let progress: UInt32
}

class GreenAddressService {

    private var session: Session?
    private var twoFactorReset: TwoFactorReset?
    private var events = [Event]()
    static var isTemporary = false
    var blockHeight: UInt32 = 0
    var isWatchOnly: Bool = false

    public init() {
        let url = try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(Bundle.main.bundleIdentifier!, isDirectory: true)
        try? FileManager.default.createDirectory(atPath: url.path, withIntermediateDirectories: true, attributes: nil)
        try! gdkInit(config: ["datadir": url.path])
        session = try! Session(notificationCompletionHandler: newNotification)
    }

    func reset() {
        Settings.shared = nil
        twoFactorReset = nil
        events = [Event]()
        blockHeight = 0
        isWatchOnly = false
        GreenAddressService.isTemporary = false
        Ledger.shared.xPubsCached.removeAll()
    }

    func getSession() -> Session {
        return self.session!
    }

    func getTwoFactorReset() -> TwoFactorReset? {
        return twoFactorReset
    }

    func getEvents() -> [Event] {
        return events
    }

    func getBlockheight() -> UInt32 {
        return blockHeight
    }

    func newNotification(notification: [String: Any]?) {
        guard let notificationEvent = notification?["event"] as? String,
                let event = EventType(rawValue: notificationEvent),
                let data = notification?[event.rawValue] as? [String: Any] else {
            return
        }
        switch event {
        case .Block:
            guard let height = data["block_height"] as? UInt32 else { break }
            blockHeight = height
            post(event: .Block, data: data)
        case .Transaction:
            post(event: .Transaction, data: data)
            do {
                let json = try JSONSerialization.data(withJSONObject: data, options: [])
                let txEvent = try JSONDecoder().decode(TransactionEvent.self, from: json)
                events.append(Event(value: data))
                if txEvent.type == "incoming" {
                    txEvent.subAccounts.forEach { pointer in
                        post(event: .AddressChanged, data: ["pointer": UInt32(pointer)])
                    }
                    DispatchQueue.main.async {
                        DropAlert().success(message: NSLocalizedString("id_new_transaction", comment: ""))
                    }
                }
            } catch { break }
        case .TwoFactorReset:
            do {
                let json = try JSONSerialization.data(withJSONObject: data, options: [])
                self.twoFactorReset = try JSONDecoder().decode(TwoFactorReset.self, from: json)
                events.removeAll(where: { $0.kindOf(TwoFactorReset.self)})
                if self.twoFactorReset!.isResetActive {
                    events.append(Event(value: data))
                }
            } catch { break }
            post(event: .TwoFactorReset, data: data)
        case .Settings:
            reloadSystemMessage()
            Settings.shared = Settings.from(data)
            if !isWatchOnly {
                reloadTwoFactor()
            }
            post(event: .Settings, data: data)
        case .Session:
            post(event: EventType.Network, data: data)
        case .Network:
            guard let json = try? JSONSerialization.data(withJSONObject: data, options: []),
                  let connection = try? JSONDecoder().decode(Connection.self, from: json) else {
                return
            }
            if !connection.connected || !(connection.loginRequired ?? false) {
                post(event: EventType.Network, data: data)
                return
            }
            guard let hw = HWResolver.shared.hw else {
                // Login required without hw
                DispatchQueue.main.async {
                    let appDelegate = UIApplication.shared.delegate as? AppDelegate
                    appDelegate?.logout(with: false)
                }
                return
            }
            if hw.connected {
                // Restore connection with hw through hidden login
                post(event: EventType.Network, data: data)
                reconnect()
            }
        case .Tor:
            post(event: .Tor, data: data)
        default:
            break
        }
    }

    func reconnect() {
        let bgq = DispatchQueue.global(qos: .background)
        let session = getSession()
        Guarantee().map(on: bgq) {_ -> TwoFactorCall in
            try session.login(mnemonic: "", hw_device: ["device": HWResolver.shared.hw?.info ?? [:]])
        }.then(on: bgq) { call in
            call.resolve()
        }.done { _ in
        }.catch { err in
            print("Error on reconnected with hw: \(err.localizedDescription)")
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
            appDelegate?.logout(with: false)
        }
    }

    func post(event: EventType, data: [String: Any]) {
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: event.rawValue), object: nil, userInfo: data)
    }

    func reloadTwoFactor() {
        events.removeAll(where: { $0.kindOf(Settings.self)})
        let bgq = DispatchQueue.global(qos: .background)
        Guarantee().map(on: bgq) {
            try self.getSession().getTwoFactorConfig()
        }.done { dataTwoFactorConfig in
            let twoFactorConfig = try JSONDecoder().decode(TwoFactorConfig.self, from: JSONSerialization.data(withJSONObject: dataTwoFactorConfig!, options: []))
            let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.shared), options: .allowFragments) as? [String: Any]
            if twoFactorConfig.enableMethods.count <= 1 {
                self.events.append(Event(value: data!))
            }
        }.catch { _ in
                print("Error on get settings")
        }
    }

    func reloadSystemMessage() {
        events.removeAll(where: { $0.kindOf(SystemMessage.self)})
        let bgq = DispatchQueue.global(qos: .background)
        Guarantee().map(on: bgq) {
            try self.getSession().getSystemMessage()
        }.done { text in
            if !text.isEmpty {
                self.events.append(Event(value: ["text": text]))
            }
        }.catch { _ in
            print("Error on get system message")
        }
    }
}
