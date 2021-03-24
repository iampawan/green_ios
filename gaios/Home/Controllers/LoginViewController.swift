import Foundation
import UIKit
import PromiseKit

class LoginViewController: UIViewController {

    @IBOutlet weak var lblTitle: UILabel!
    @IBOutlet weak var attempts: UILabel!

    @IBOutlet weak var cancelButton: UIButton!
    @IBOutlet weak var deleteButton: UIButton!
    @IBOutlet var keyButton: [UIButton]?
    @IBOutlet var pinLabel: [UILabel]?
    let menuButton = UIButton(type: .system)

    private var pinCode = ""
    private let MAXATTEMPTS = 3
    private var network = { return getNetwork() }()

    var pinAttemptsPreference: Int {
        get {
            return UserDefaults.standard.integer(forKey: getNetwork() + "_pin_attempts")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: getNetwork() + "_pin_attempts")
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let navigationBarHeight: CGFloat =  navigationController!.navigationBar.frame.height
        let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: navigationBarHeight, height: navigationBarHeight))
        imageView.contentMode = .scaleAspectFit
        let imageName = getGdkNetwork(network).liquid ? "btc_liquid" : getGdkNetwork(network).icon
        imageView.image = UIImage(named: imageName!)
        navigationItem.titleView = imageView
        navigationItem.setHidesBackButton(true, animated: false)
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage.init(named: "backarrow"), style: UIBarButtonItem.Style.plain, target: self, action: #selector(PinLoginViewController.back))
        menuButton.setImage(UIImage(named: "ellipses"), for: .normal)
        menuButton.addTarget(self, action: #selector(menuButtonTapped), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: menuButton)
        lblTitle.text = NSLocalizedString("id_enter_pin", comment: "")
        progressIndicator?.message = NSLocalizedString("id_logging_in", comment: "")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ScreenLocker.shared.stopObserving()
        NotificationCenter.default.addObserver(self, selector: #selector(progress), name: NSNotification.Name(rawValue: EventType.Tor.rawValue), object: nil)

        cancelButton.addTarget(self, action: #selector(click(sender:)), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(click(sender:)), for: .touchUpInside)
        for button in keyButton!.enumerated() {
            button.element.addTarget(self, action: #selector(keyClick(sender:)), for: .touchUpInside)
        }
        updateAttemptsLabel()
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        let bioAuth = AuthenticationTypeHandler.findAuth(method: AuthenticationTypeHandler.AuthKeyBiometric, forNetwork: network)
        if bioAuth {
            loginWithPin(usingAuth: AuthenticationTypeHandler.AuthKeyBiometric, network: network, withPIN: nil)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ScreenLocker.shared.startObserving()
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: EventType.Tor.rawValue), object: nil)

        cancelButton.removeTarget(self, action: #selector(click(sender:)), for: .touchUpInside)
        deleteButton.removeTarget(self, action: #selector(click(sender:)), for: .touchUpInside)
        for button in keyButton!.enumerated() {
            button.element.removeTarget(self, action: #selector(keyClick(sender:)), for: .touchUpInside)
        }
    }

    @objc func menuButtonTapped(_ sender: Any) {
        let storyboard = UIStoryboard(name: "PopoverMenu", bundle: nil)
        if let popover  = storyboard.instantiateViewController(withIdentifier: "PopoverMenuWalletViewController") as? PopoverMenuWalletViewController {
            popover.delegate = self
            popover.modalPresentationStyle = .popover
            let popoverPresentationController = popover.popoverPresentationController
            popoverPresentationController?.backgroundColor = UIColor.customModalDark()
            popoverPresentationController?.delegate = self
            popoverPresentationController?.sourceView = self.menuButton
            popoverPresentationController?.sourceRect = self.menuButton.bounds
            self.present(popover, animated: true)
        }
    }

    @objc func progress(_ notification: NSNotification) {
        Guarantee().map { () -> UInt32 in
            let json = try JSONSerialization.data(withJSONObject: notification.userInfo!, options: [])
            let tor = try JSONDecoder().decode(Tor.self, from: json)
            return tor.progress
        }.done { progress in
            var text = NSLocalizedString("id_tor_status", comment: "") + " \(progress)%"
            if progress == 100 {
                text = NSLocalizedString("id_logging_in", comment: "")
            }
            self.progressIndicator?.message = text
        }.catch { err in
            print(err.localizedDescription)
        }
    }

    fileprivate func loginWithPin(usingAuth: String, network: String, withPIN: String?) {
        let bgq = DispatchQueue.global(qos: .background)
        let appDelegate = getAppDelegate()!

        firstly {
            return Guarantee()
        }.compactMap {
            try AuthenticationTypeHandler.getAuth(method: usingAuth, forNetwork: network)
        }.get { _ in
            self.startAnimating(message: NSLocalizedString("id_logging_in", comment: ""))
        }.get(on: bgq) { _ in
            appDelegate.disconnect()
        }.get(on: bgq) { _ in
            try appDelegate.connect()
        }.compactMap(on: bgq) {data -> TwoFactorCall in
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let pin = withPIN ?? data["plaintext_biometric"] as? String
            let pinData = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
            return try getSession().loginWithPin(pin: pin!, pin_data: pinData!)
        }.then(on: bgq) { twoFactorCall in
            twoFactorCall.resolve()
        }.then { _ in
            Registry.shared.refresh().recover { _ in Guarantee() }
        }.ensure {
            self.stopAnimating()
        }.done {
            self.pinAttemptsPreference = 0
            appDelegate.instantiateViewControllerAsRoot(storyboard: "Wallet", identifier: "TabViewController")
        }.catch { error in
            var message = NSLocalizedString("id_login_failed", comment: "")
            if let authError = error as? AuthenticationTypeHandler.AuthError {
                switch authError {
                case .CanceledByUser:
                    return
                case .SecurityError, .KeychainError:
                    return self.onBioAuthError(authError.localizedDescription)
                default:
                    message = authError.localizedDescription
                }
            } else if let error = error as? TwoFactorCallError {
                switch error {
                case .failure(let localizedDescription), .cancel(let localizedDescription):
                    if localizedDescription.contains(":login failed:") && withPIN != nil {
                        self.wrongPin()
                    }
                }
            }
            self.pinCode = ""
            self.updateAttemptsLabel()
            self.reload()
            DropAlert().error(message: message)
        }
    }

    func wrongPin() {
        self.pinAttemptsPreference += 1
        if self.pinAttemptsPreference == self.MAXATTEMPTS {
            removeKeychainData()
            self.pinAttemptsPreference = 0
            getAppDelegate()?.instantiateViewControllerAsRoot(storyboard: "Main", identifier: "InitialViewController")
        }
    }

    func onBioAuthError(_ message: String) {
        let text = String(format: NSLocalizedString("id_syou_need_ton1_reset_greens", comment: ""), message)
        let alert = UIAlertController(title: NSLocalizedString("id_warning", comment: ""), message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_cancel", comment: ""), style: .default) { _ in })
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_reset", comment: ""), style: .destructive) { _ in
            removeBioKeychainData()
            try? AuthenticationTypeHandler.removePrivateKey(forNetwork: self.network)
            UserDefaults.standard.set(nil, forKey: "AuthKeyBiometricPrivateKey" + self.network)
        })
        DispatchQueue.main.async {
            self.present(alert, animated: true, completion: nil)
        }
    }

    func updateAttemptsLabel() {
        if MAXATTEMPTS - pinAttemptsPreference == 1 {
            attempts.text = NSLocalizedString("id_last_attempt_if_failed_you_will", comment: "")
        } else {
            attempts.text = String(format: NSLocalizedString("id_attempts_remaining_d", comment: ""), MAXATTEMPTS - pinAttemptsPreference)
        }
        attempts.isHidden = pinAttemptsPreference == 0
    }

    @objc func keyClick(sender: UIButton) {
        pinCode += (sender.titleLabel?.text)!
        reload()
        guard pinCode.count == 6 else {
            return
        }
        let network = getNetwork()
        loginWithPin(usingAuth: AuthenticationTypeHandler.AuthKeyPIN, network: network, withPIN: self.pinCode)
    }

    func reload() {
        pinLabel?.enumerated().forEach {(index, label) in
            if index < pinCode.count {
                label.textColor = UIColor.customMatrixGreen()
            } else {
                label.textColor = UIColor.black
            }
        }
    }

    @objc func back(sender: UIBarButtonItem) {
        navigationController?.popViewController(animated: true)
//        getAppDelegate()!.instantiateViewControllerAsRoot(storyboard: "Main", identifier: "InitialViewController")
    }

    @objc func click(sender: UIButton) {
        if sender == deleteButton {
            if pinCode.count > 0 {
                pinCode.removeLast()
            }
        } else if sender == cancelButton {
            pinCode = ""
        }
        reload()
    }

    func walletDelete() {
        let storyboard = UIStoryboard(name: "Shared", bundle: nil)
        if let vc = storyboard.instantiateViewController(withIdentifier: "DialogWalletDeleteViewController") as? DialogWalletDeleteViewController {
            vc.modalPresentationStyle = .overFullScreen
            vc.delegate = self
            present(vc, animated: false, completion: nil)
        }
    }

    func walletRename() {
        let storyboard = UIStoryboard(name: "Shared", bundle: nil)
        if let vc = storyboard.instantiateViewController(withIdentifier: "DialogWalletNameViewController") as? DialogWalletNameViewController {
            vc.modalPresentationStyle = .overFullScreen
            vc.delegate = self
            present(vc, animated: false, completion: nil)
        }
    }

    @IBAction func btnFaceID(_ sender: Any) {
    }

    @IBAction func btnSettings(_ sender: Any) {
        let storyboard = UIStoryboard(name: "OnBoard", bundle: nil)
        let vc = storyboard.instantiateViewController(withIdentifier: "WalletSettingsViewController")
        present(vc, animated: true) {
        }
    }

}

extension LoginViewController: DialogWalletNameViewControllerDelegate, DialogWalletDeleteViewControllerDelegate {
    func didSave(_ name: String) {
        print(name)
    }
    func didDelete() {
        print("Remove Wallet")
    }
    func didCancel() {
        print("Cancel")
    }
}

extension LoginViewController: PopoverMenuWalletDelegate {
    func didSelectionMenuOption(_ menuOption: MenuWalletOption) {
        switch menuOption {
        case .edit:
            walletRename()
        case .delete:
            walletDelete()
        }
    }
}

extension LoginViewController: UIPopoverPresentationControllerDelegate {

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
    }

    func presentationController(_ controller: UIPresentationController, viewControllerForAdaptivePresentationStyle style: UIModalPresentationStyle) -> UIViewController? {
        return UINavigationController(rootViewController: controller.presentedViewController)
    }
}
