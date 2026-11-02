// Copyright 2026 T-Dash contributors. SPDX-License-Identifier: Apache-2.0
// Native iOS adaptation of T-Dash's cluster. Vehicle data remains Tesla BLE data.
import UIKit

private let tdMint = UIColor(red: 0.40, green: 0.96, blue: 0.81, alpha: 1)
private let tdPrefs = UserDefaults(suiteName: "com.caun.tdash.amap")!

private func tdFont(_ size: CGFloat) -> UIFont {
    UIFont(name: "PingFangSC-Medium", size: size) ?? .systemFont(ofSize: size, weight: .medium)
}

final class TDOverlayWindow: UIWindow {
    weak var dashboard: TDDashboardController?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let controller = dashboard else { return nil }
        if controller.presentedViewController != nil { return super.hitTest(point, with: event) }
        let local = controller.panel.convert(point, from: self)
        guard controller.panel.bounds.contains(local) else { return nil }
        return super.hitTest(point, with: event)
    }
}

final class TDDashboardController: UIViewController, UIGestureRecognizerDelegate {
    let client: TDTeslaClient
    let panel = UIView()
    private let speed = UILabel()
    private let speedUnit = UILabel()
    private let lockFeedback = UILabel()
    private var feedbackWork: DispatchWorkItem?
    private var panGesture: UIPanGestureRecognizer!
    private(set) var positionLocked = tdPrefs.bool(forKey: "capsule.positionLocked")
    private let gear = UILabel()
    private let range = UILabel()
    private let leftDivider = UIView()
    private let rightDivider = UIView()
    private var timer: Timer?
    private var orientationKey = ""
    private var dragOrigin = CGPoint.zero
    private var landscape: Bool { view.bounds.width > view.bounds.height }
    weak var hostKeyWindow: UIWindow?

    init(client: TDTeslaClient) { self.client = client; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        panel.layer.borderWidth = 0.5
        panel.layer.borderColor = UIColor.white.withAlphaComponent(0.65).cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowRadius = 8
        panel.layer.shadowOpacity = 0.16
        panel.layer.shadowOffset = CGSize(width: 0, height: 3)
        view.addSubview(panel)
        [speed, speedUnit, gear, range, leftDivider, rightDivider].forEach(panel.addSubview)
        for label in [speed, speedUnit, gear, range] {
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.textColor = UIColor(red: 0.025, green: 0.045, blue: 0.065, alpha: 1)
        }
        speed.accessibilityIdentifier = "tdash.speed"
        speedUnit.accessibilityIdentifier = "tdash.speedUnit"
        speedUnit.text = "km/h"
        speedUnit.isAccessibilityElement = false
        speed.adjustsFontSizeToFitWidth = false
        speedUnit.adjustsFontSizeToFitWidth = false
        speed.textAlignment = .right
        speedUnit.textAlignment = .left
        lockFeedback.font = tdFont(13)
        lockFeedback.textAlignment = .center
        lockFeedback.textColor = .white
        lockFeedback.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        lockFeedback.layer.cornerRadius = 12; lockFeedback.clipsToBounds = true
        lockFeedback.isUserInteractionEnabled = false; lockFeedback.isHidden = true
        view.addSubview(lockFeedback)
        gear.backgroundColor = tdMint
        gear.clipsToBounds = true
        for divider in [leftDivider, rightDivider] {
            divider.backgroundColor = UIColor.black.withAlphaComponent(0.13)
        }
        updateLockHint()
        panel.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "打开仪表设置", target: self, selector: #selector(accessibilitySettings)),
            UIAccessibilityCustomAction(name: "锁定或解锁位置", target: self, selector: #selector(accessibilityLock))
        ]
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self; panel.addGestureRecognizer(pan)
        panGesture = pan; pan.isEnabled = !positionLocked
        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(togglePositionLock))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.numberOfTouchesRequired = 1
        tripleTap.delegate = self; panel.addGestureRecognizer(tripleTap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.65; hold.allowableMovement = 10
        hold.delegate = self; panel.addGestureRecognizer(hold)
        client.onChange = { [weak self] in self?.refresh() }
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.15
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
    }
    deinit { timer?.invalidate(); feedbackWork?.cancel() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layoutPanel() }
    private var safeFrame: CGRect { view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 10, dy: 10) }
    private func layoutPanel() {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        let safe = safeFrame
        let width = min(landscape ? 360 : 320, safe.width)
        let scale = width / 360
        let size = CGSize(width: width, height: 68 * scale)
        let key = landscape ? "landscape" : "portrait"
        let changed = orientationKey != key || panel.bounds.size != size
        panel.bounds = CGRect(origin: .zero, size: size)
        if changed {
            orientationKey = key
            let x = tdPrefs.object(forKey: "capsule.position.\(key).x") as? Double ?? 0.98
            let y = tdPrefs.object(forKey: "capsule.position.\(key).y") as? Double ?? (landscape ? 0.02 : 0.22)
            panel.frame.origin = CGPoint(x: safe.minX + CGFloat(x) * max(0, safe.width - size.width),
                                         y: safe.minY + CGFloat(y) * max(0, safe.height - size.height))
        }
        clampPanel()
        let opacity = tdPrefs.object(forKey: "capsule.opacity") as? Double ?? 0.94
        panel.backgroundColor = UIColor(red: 0.96, green: 0.975, blue: 1, alpha: CGFloat(max(0, min(1, opacity))))
        panel.layer.cornerRadius = 30 * scale
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
        }
        // Separate fixed-width views reserve space for every three-digit speed.
        // Align on a shared font baseline rather than squeezing number and unit together.
        speed.font = tdFont(38 * scale)
        speedUnit.font = tdFont(13 * scale)
        let baseline = 46 * scale
        speed.frame = CGRect(x: 14 * scale, y: baseline - speed.font.ascender,
                             width: 86 * scale, height: speed.font.lineHeight)
        speedUnit.frame = CGRect(x: 108 * scale, y: baseline - speedUnit.font.ascender,
                                 width: 35 * scale, height: speedUnit.font.lineHeight)
        leftDivider.frame = rect(152, 19, 1, 30)
        gear.frame = rect(172, 14, 48, 40)
        gear.font = tdFont(29 * scale)
        gear.layer.cornerRadius = 15 * scale
        rightDivider.frame = rect(240, 19, 1, 30)
        range.frame = rect(250, 13, 98, 43)
        layoutLockFeedback()
        updateReadings(scale: scale)
    }
    private func clampPanel() {
        let safe = safeFrame
        panel.frame.origin = CGPoint(x: max(safe.minX, min(panel.frame.minX, safe.maxX - panel.bounds.width)),
                                     y: max(safe.minY, min(panel.frame.minY, safe.maxY - panel.bounds.height)))
    }
    private func fresh(_ date: Date?, seconds: TimeInterval = 3) -> Bool {
        guard let date = date else { return false }
        return client.isConnected && (-1...seconds).contains(Date().timeIntervalSince(date))
    }
    private func reading(_ value: String, unit: String, font: CGFloat, scale: CGFloat) -> NSAttributedString {
        let text = NSMutableAttributedString(string: value, attributes: [
            .font: tdFont(font * scale)
        ])
        text.append(NSAttributedString(string: " " + unit, attributes: [.font: tdFont(14 * scale)]))
        return text
    }
    private func updateReadings(scale: CGFloat) {
        let speedValue = fresh(client.speedUpdatedAt) ? client.telemetry.speedKph : nil
        let speedText: String
        if let value = speedValue, value.isFinite, (0...350).contains(value) {
            speedText = String(format: "%.0f", ceil(value))
        } else { speedText = "—" }
        speed.text = speedText
        gear.text = fresh(client.gearUpdatedAt) ? (client.telemetry.gear ?? "—") : "—"
        let rangeValue = client.isConnected && client.rangeUpdatedAt != nil ? client.telemetry.rangeKm : nil
        var rangeText = "—"
        let old = rangeValue != nil && !fresh(client.rangeUpdatedAt, seconds: 45)
        if let value = rangeValue, value.isFinite, (0...2000).contains(value) {
            rangeText = String(format: "%.0f", value)
        }
        range.attributedText = reading(rangeText, unit: old ? "km*" : "km", font: 29, scale: scale)
        speed.accessibilityLabel = "车速 \(speedText) 公里每小时"
        gear.accessibilityLabel = "挡位 \(gear.text ?? "未知")"
        range.accessibilityLabel = "\(old ? "上次驻车" : "车辆")续航 \(rangeText) 公里"
    }
    func refresh() {
        guard isViewLoaded else { return }
        layoutPanel()
        (presentedViewController as? TDSettingsController)?.updateStatus()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        guard !positionLocked else { return }
        if recognizer.state == .began { dragOrigin = panel.frame.origin }
        let delta = recognizer.translation(in: view)
        panel.frame.origin = CGPoint(x: dragOrigin.x + delta.x, y: dragOrigin.y + delta.y)
        clampPanel()
        if recognizer.state == .ended || recognizer.state == .cancelled {
            let safe = safeFrame
            tdPrefs.set(Double((panel.frame.minX - safe.minX) / max(1, safe.width - panel.bounds.width)), forKey: "capsule.position.\(orientationKey).x")
            tdPrefs.set(Double((panel.frame.minY - safe.minY) / max(1, safe.height - panel.bounds.height)), forKey: "capsule.position.\(orientationKey).y")
        }
    }
    private func updateLockHint() {
        panel.accessibilityHint = positionLocked ? "位置已锁定，三连点解锁，长按打开设置" : "拖动调整位置，三连点锁定，长按打开设置"
    }
    private func layoutLockFeedback() {
        let safe = safeFrame
        let width = min(190, safe.width)
        let y = panel.frame.maxY + 8 + 30 <= safe.maxY ? panel.frame.maxY + 8 : panel.frame.minY - 38
        lockFeedback.frame = CGRect(x: max(safe.minX, min(panel.frame.midX - width / 2, safe.maxX - width)),
                                    y: max(safe.minY, y), width: width, height: 30)
    }
    @objc func togglePositionLock() {
        positionLocked.toggle()
        tdPrefs.set(positionLocked, forKey: "capsule.positionLocked")
        panGesture.isEnabled = !positionLocked
        updateLockHint()
        let message = positionLocked ? "位置已锁定 · 三连点解锁" : "位置已解锁 · 可拖动"
        lockFeedback.text = message
        layoutLockFeedback(); lockFeedback.isHidden = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: message)
        feedbackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lockFeedback.isHidden = true }
        feedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
        (presentedViewController as? TDSettingsController)?.updateStatus()
    }
    @objc private func accessibilityLock() -> Bool { togglePositionLock(); return true }
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) { if recognizer.state == .began { openSettings() } }
    @objc private func accessibilitySettings() -> Bool { openSettings(); return true }
    @objc func openSettings() {
        guard presentedViewController == nil else { return }
        hostKeyWindow = view.window?.windowScene?.windows.first { $0.isKeyWindow && $0 !== view.window }
        view.window?.makeKey()
        let settings = TDSettingsController(dashboard: self, client: client)
        settings.modalPresentationStyle = .overFullScreen
        present(settings, animated: true)
    }
    func closeSettings() {
        dismiss(animated: true) { [weak self] in self?.hostKeyWindow?.makeKey(); self?.refresh() }
    }
    func setOpacity(_ value: Float) { tdPrefs.set(Double(value), forKey: "capsule.opacity"); layoutPanel() }
}

final class TDSettingsController: UIViewController {
    private weak var dashboard: TDDashboardController?
    private let client: TDTeslaClient
    private let vinField = UITextField()
    private let status = UILabel()
    private let opacityLabel = UILabel()
    private let card = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var keyboardHeight: CGFloat = 0
    init(dashboard: TDDashboardController, client: TDTeslaClient) {
        self.dashboard = dashboard; self.client = client; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        card.backgroundColor = UIColor(red: 0.055, green: 0.08, blue: 0.10, alpha: 0.98)
        card.layer.cornerRadius = 24; card.clipsToBounds = true
        view.addSubview(card); card.addSubview(scroll)
        scroll.keyboardDismissMode = .interactive
        stack.axis = .vertical; stack.spacing = 13; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -44)
        ])
        addText("T–DASH", size: 25, color: tdMint)
        addText("特斯拉蓝牙仪表 · 高德悬浮版", size: 14)
        addText("三连点锁定／解锁位置 · 长按 0.65 秒打开设置\n解锁时可拖动；锁定状态会保存，横竖屏分别记住位置。", size: 12, color: .lightGray)
        vinField.font = tdFont(16)
        vinField.placeholder = "车辆 VIN（17 位）"
        vinField.text = tdPrefs.string(forKey: "vin") ?? ""
        vinField.borderStyle = .roundedRect; vinField.autocapitalizationType = .allCharacters
        vinField.autocorrectionType = .no; vinField.spellCheckingType = .no
        vinField.keyboardType = .asciiCapable; vinField.returnKeyType = .done
        vinField.accessibilityLabel = "车辆 VIN"
        vinField.heightAnchor.constraint(equalToConstant: 44).isActive = true
        vinField.addTarget(self, action: #selector(connect), for: .editingDidEndOnExit)
        stack.addArrangedSubview(vinField)
        addButton("连接车辆", action: #selector(connect))
        addButton("首次使用：添加蓝牙钥匙", action: #selector(pair))
        status.numberOfLines = 0; status.font = tdFont(13); status.textColor = tdMint
        stack.addArrangedSubview(status)
        addText("先连接，再添加钥匙；按车机提示用实体卡片确认。私钥仅存储于本机钥匙串。", size: 12, color: .lightGray)
        let slider = UISlider()
        slider.minimumValue = 0; slider.maximumValue = 1
        slider.value = Float(tdPrefs.object(forKey: "capsule.opacity") as? Double ?? 0.94)
        slider.tintColor = tdMint; slider.accessibilityLabel = "仪表底色不透明度"
        slider.addTarget(self, action: #selector(opacityChanged(_:)), for: .valueChanged)
        opacityLabel.font = tdFont(13); stack.addArrangedSubview(opacityLabel)
        stack.addArrangedSubview(slider); opacityChanged(slider)
        addText("仪表只显示车速、挡位、车辆续航。背景可调透明度，黑色数字适合浅色底。\n车速与挡位超时 3 秒清空。续航来自车辆 battery_range，在停车时更新；超过 45 秒标 *，表示上次驻车读数，断连后清空。", size: 12, color: .lightGray)
        addButton("断开蓝牙", action: #selector(disconnect))
        addButton("完成", action: #selector(close))
        updateStatus()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func addText(_ text: String, size: CGFloat, color: UIColor = .white) {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = tdFont(size); label.textColor = color; stack.addArrangedSubview(label)
    }
    private func addButton(_ text: String, action: Selector) {
        let button = UIButton(type: .system)
        button.setTitle(text, for: .normal); button.tintColor = tdMint
        button.titleLabel?.font = tdFont(16)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.07); button.layer.cornerRadius = 10
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside); stack.addArrangedSubview(button)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 16, dy: 12)
        safe.size.height = max(100, safe.height - keyboardHeight)
        let width = min(440, safe.width), height = min(700, safe.height)
        card.frame = CGRect(x: safe.midX - width / 2, y: safe.minY + (safe.height - height) / 2, width: width, height: height)
        scroll.frame = card.bounds
    }
    @objc private func keyboard(_ note: Notification) {
        if let rect = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let converted = view.convert(rect, from: nil)
            keyboardHeight = max(0, view.bounds.maxY - converted.minY - view.safeAreaInsets.bottom)
            view.setNeedsLayout(); view.layoutIfNeeded()
            if vinField.isFirstResponder { scroll.scrollRectToVisible(vinField.convert(vinField.bounds, to: scroll), animated: true) }
        }
    }
    func updateStatus() { status.text = client.status + "\n" + (dashboard?.positionLocked == true ? "位置已锁定（三连点可解锁）" : "位置未锁定（三连点可锁定）") }
    @objc private func connect() {
        view.endEditing(true)
        let vin = (vinField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        vinField.text = vin
        guard vin.range(of: "^[A-HJ-NPR-Z0-9]{17}$", options: .regularExpression) != nil else {
            status.text = "请输入有效的 17 位 VIN（不含 I、O、Q）"; return
        }
        tdPrefs.set(vin, forKey: "vin"); client.connect(vin: vin); updateStatus()
    }
    @objc private func pair() {
        view.endEditing(true)
        let alert = UIAlertController(title: "添加 T-Dash 蓝牙钥匙", message: "请在停车状态下操作。将按原版 T-Dash 的方式添加 Owner 级蓝牙钥匙，请按车机提示将实体钥匙卡放到读卡区。本插件只发送仪表读取请求。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "开始配对", style: .default) { [weak self] _ in self?.client.pair(); self?.updateStatus() })
        present(alert, animated: true)
    }
    @objc private func disconnect() { client.disconnect(); updateStatus() }
    @objc private func close() { view.endEditing(true); dashboard?.closeSettings() }
    @objc private func opacityChanged(_ slider: UISlider) {
        dashboard?.setOpacity(slider.value)
        opacityLabel.text = "底色不透明度  \(Int(slider.value * 100))%"
    }
}

private final class TDOverlayCoordinator: NSObject {
    static let shared = TDOverlayCoordinator()
    private let client = TDTeslaClient()
    private var window: TDOverlayWindow?
    private var observers: [NSObjectProtocol] = []
    func start() {
        guard Bundle.main.bundleIdentifier == "com.autonavi.amap", observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sync() })
        }
        sync()
    }
    private func sync() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }
        guard UIApplication.shared.applicationState == .active, let scene = scene else {
            window?.isHidden = true; client.setActive(false); return
        }
        if window?.windowScene !== scene {
            window?.isHidden = true
            let overlay = TDOverlayWindow(windowScene: scene)
            let controller = TDDashboardController(client: client)
            overlay.backgroundColor = .clear
            overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 5)
            overlay.dashboard = controller; overlay.rootViewController = controller
            window = overlay
        }
        window?.isHidden = false
        client.setActive(true)
    }
}

@_cdecl("TDashStart")
public func TDashStart() {
    DispatchQueue.main.async { TDOverlayCoordinator.shared.start() }
}
