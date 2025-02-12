import Foundation
import UIKit
import PromiseKit

enum TransactionDetailCellType {
    case status
    case asset
    case fee
    case amount
    case recipient
    case wallet
    case notes
    case txident
}

extension TransactionDetailCellType: CaseIterable {}

class TransactionDetailViewController: KeyboardViewController {

    @IBOutlet weak var viewInExplorerButton: UIButton!
    @IBOutlet weak var transactionDetailTableView: UITableView!

    var wallet: WalletItem!
    var transaction: Transaction!

    private var cellTypes = TransactionDetailCellType.allCases
    private var isLiquid: Bool = false
    private var isIncoming: Bool = false
    private var isRedeposit: Bool = false

    private var account = AccountsManager.shared.current
    private var amounts: [(key: String, value: UInt64)] {
        get {
            return Transaction.sort(transaction.amounts)
        }
    }

    var viewInExplorerPreference: Bool {
        get {
            return UserDefaults.standard.bool(forKey: getNetwork() + "_view_in_explorer")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: getNetwork() + "_view_in_explorer")
        }
    }

    private var transactionToken: NSObjectProtocol?
    private var blockToken: NSObjectProtocol?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        transactionToken = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: EventType.Transaction.rawValue), object: nil, queue: .main, using: refreshTransaction)
        blockToken = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: EventType.Block.rawValue), object: nil, queue: .main, using: refreshTransaction)
        transactionDetailTableView.reloadData()
        let shareButton = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareButtonTapped))
        navigationItem.rightBarButtonItem = shareButton
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let token = transactionToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = blockToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func configureViewAndCells() {
        isIncoming = transaction.type == "incoming"
        isRedeposit = transaction.type == "redeposit"
        isLiquid = account?.gdkNetwork.liquid ?? false
        cellTypes.remove(at: cellTypes.firstIndex(of: .asset)!)
        if isLiquid {
            if isIncoming {
                for _ in amounts {
                    cellTypes.insert(.asset, at: 1)
                }
            } else {
                cellTypes.insert(.asset, at: 1)
            }
            _ = isRedeposit || amounts.count > 0 ?
                cellTypes.remove(at: cellTypes.firstIndex(of: .amount)!) :
                cellTypes.remove(at: cellTypes.firstIndex(of: .fee)!)
        }
        _ = isIncoming || isRedeposit ? cellTypes.remove(at: cellTypes.firstIndex(of: .recipient)!) : cellTypes.remove(at: cellTypes.firstIndex(of: .wallet)!)
        if isRedeposit {
            title = NSLocalizedString("id_redeposited", comment: "")
        } else if isIncoming {
            title = NSLocalizedString("id_received_on", comment: "")
        } else {
            title = NSLocalizedString("id_sent", comment: "")
        }
        viewInExplorerButton.setTitle(NSLocalizedString("id_view_in_explorer", comment: ""), for: .normal)
        viewInExplorerButton.setGradient(true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViewAndCells()
        let nib = UINib(nibName: "AssetTableCell", bundle: nil)
        transactionDetailTableView.register(nib, forCellReuseIdentifier: "AssetTableCell")
        transactionDetailTableView.delegate = self
        transactionDetailTableView.dataSource = self
        transactionDetailTableView.sectionHeaderHeight = UITableView.automaticDimension
        transactionDetailTableView.estimatedSectionHeaderHeight = 50
        transactionDetailTableView.rowHeight = UITableView.automaticDimension
        transactionDetailTableView.estimatedRowHeight = 50
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        viewInExplorerButton.updateGradientLayerFrame()
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let next = segue.destination as? SendBtcDetailsViewController {
            next.transaction = sender as? Transaction
            next.wallet = wallet
        } else if let next = segue.destination as? AssetDetailTableViewController {
            next.tag = sender as? String
            if let asset = Registry.shared.infos[next.tag] {
                next.asset = asset
            } else {
                next.asset = AssetInfo(assetId: next.tag,
                                       name: NSLocalizedString("id_no_registered_name_for_this", comment: ""),
                                       precision: 0,
                                       ticker: NSLocalizedString("id_no_registered_ticker_for_this", comment: ""))
            }
            next.satoshi = wallet?.satoshi[next.tag]
        } else if let next = segue.destination as? NotesViewController {
            next.transaction = sender as? Transaction
            next.updateTransaction = { transaction in
                self.transaction = transaction
                self.transactionDetailTableView.reloadData()
            }
        }
    }

    func urlForTx() -> URL? {
        return URL(string: account?.gdkNetwork.txExplorerUrl ?? "" + self.transaction.hash)
    }

    func explorerUrlOrAlert() -> UIAlertController? {
        guard let url: URL = urlForTx() else { return nil }
        let host = url.host!.starts(with: "www.") ? String(url.host!.prefix(5)) : url.host!
        if viewInExplorerPreference {
            UIApplication.shared.open(url, options: [:])
            return nil
        }
        let message = String(format: NSLocalizedString("id_are_you_sure_you_want_to_view", comment: ""), host)
        let alert = UIAlertController(title: "", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_cancel", comment: ""), style: .cancel) { (_: UIAlertAction) in
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_only_this_time", comment: ""), style: .default) { (_: UIAlertAction) in
            UIApplication.shared.open(url, options: [:])
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_always", comment: ""), style: .default) { (_: UIAlertAction) in
            self.viewInExplorerPreference = true
            UIApplication.shared.open(url, options: [:])
        })

        return alert
    }

    func shareTransactionSheet() -> UIAlertController {
        let alert = UIAlertController(title: NSLocalizedString("Share Transaction", comment: ""), message: "", preferredStyle: .actionSheet)
        // View the transaction in blockstream.info
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_view_in_explorer", comment: ""), style: .default) { _ in
            guard let alert: UIAlertController = self.explorerUrlOrAlert() else { return }
            self.present(alert, animated: true, completion: nil)
        })
        // Share the unblinded transaction explorer url
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_share_nonconfidential", comment: ""), style: .default) { _ in
            let unblindedUrl = self.account?.gdkNetwork.txExplorerUrl ?? "" + self.transaction.hash + self.transaction.blindingUrlString()
            let shareVC = UIActivityViewController(activityItems: [unblindedUrl], applicationActivities: nil)
            self.present(shareVC, animated: true, completion: nil)
        })
        // Share data needed to unblind the transaction
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_share_unblinding_data", comment: ""), style: .default) { _ in
            let blindingData = try? JSONSerialization.data(withJSONObject: self.transaction.blindingData() ?? "", options: [])
            let shareVC = UIActivityViewController(activityItems: [String(data: blindingData!, encoding: .utf8)!], applicationActivities: nil)
            self.present(shareVC, animated: true, completion: nil)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("id_cancel", comment: ""), style: .cancel) { _ in })
        return alert
    }

    @IBAction func shareButtonTapped(_ sender: UIButton) {
        // We have more options in liquid for confidential txs
        if isLiquid {
            let alert = shareTransactionSheet()
            self.present(alert, animated: true, completion: nil)
        } else {
            if let url = urlForTx() {
                let tx: [Any] = [url]
                let shareVC = UIActivityViewController(activityItems: tx, applicationActivities: nil)
                shareVC.popoverPresentationController?.sourceView = sender
                self.present(shareVC, animated: true, completion: nil)
            }
        }
    }

    @IBAction func viewInExplorerClicked(_ sender: Any) {
        guard let alert: UIAlertController = self.explorerUrlOrAlert() else { return }
        self.present(alert, animated: true, completion: nil)
    }

    @objc func increaseFeeTapped(_ sender: UIButton) {
        if !transaction.canRBF || getGAService().isWatchOnly || getGAService().getTwoFactorReset()!.isResetActive { return }
        let details: [String: Any] = ["previous_transaction": transaction.details, "fee_rate": transaction.feeRate, "subaccount": wallet.pointer]
        gaios.createTransaction(details: details).done { tx in
            self.performSegue(withIdentifier: "rbf", sender: tx)
        }.catch { err in
            print(err.localizedDescription)
        }
    }

    func refreshTransaction(_ notification: Notification) {
        Guarantee().done { [weak self] _ in
            DispatchQueue.main.async {
                self?.transactionDetailTableView.reloadData()
            }
        }
    }
}

extension TransactionDetailViewController: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if let headerCell = tableView.dequeueReusableCell(withIdentifier: "TransactionDetailHeaderCell") as? TransactionDetailHeaderCell {
            headerCell.configure(with: transaction.date(dateStyle: .long, timeStyle: .short))
            return headerCell
        }
        return UIView()
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return cellTypes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cellType = cellTypes[indexPath.row]
        switch cellType {
        case .status:
            if let cell = tableView.dequeueReusableCell(withIdentifier: "TransactionStatusTableCell") as? TransactionStatusTableCell {
                cell.configure(for: transaction, isLiquid: account?.gdkNetwork.liquid ?? false)
                cell.increaseFeeButton.addTarget(self, action: #selector(increaseFeeTapped), for: .touchUpInside)
                return cell
            }
        case .asset:
            if let cell = tableView.dequeueReusableCell(withIdentifier: "AssetTableCell") as? AssetTableCell,
                let amount = isIncoming ? amounts[indexPath.row - 1] : amounts.filter({ $0.key == transaction.defaultAsset}).first {
                let info = Registry.shared.infos[amount.key]
                let icon = Registry.shared.image(for: amount.key)
                cell.configure(tag: amount.key, info: info, icon: icon, satoshi: transaction.amounts[amount.key] ?? 0)
                return cell
            }
        case .amount, .txident, .fee, .recipient, .wallet, .notes:
            if let cell = tableView.dequeueReusableCell(withIdentifier: "TransactionDetailTableCell") as? TransactionDetailTableCell {
                cell.configure(for: transaction, cellType: cellType, walletName: wallet.localizedName())
                return cell
            }
        }
        return UITableViewCell()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let cellType = cellTypes[indexPath.row]
        switch cellType {
        case .status:
            if !transaction.canRBF || getGAService().isWatchOnly || getGAService().getTwoFactorReset()!.isResetActive { return }
            let details: [String: Any] = ["previous_transaction": transaction.details, "fee_rate": transaction.feeRate, "subaccount": wallet.pointer]
            gaios.createTransaction(details: details).done { tx in
                self.performSegue(withIdentifier: "rbf", sender: tx)
                }.catch { err in
                    print(err.localizedDescription)
            }
        case .asset:
            if isLiquid {
                if let amount = isIncoming ? amounts[indexPath.row - 1] : amounts.filter({ $0.key == transaction.defaultAsset}).first {
                   self.performSegue(withIdentifier: "asset", sender: amount.key)
                }
            }
        case .notes:
            self.performSegue(withIdentifier: "notes", sender: transaction)
        default:
            break
        }
    }
}
