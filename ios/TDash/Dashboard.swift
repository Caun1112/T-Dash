// Copyright 2026 T-Dash contributors. SPDX-License-Identifier: Apache-2.0
// Native iOS adaptation of T-Dash's cluster. Vehicle data remains Tesla BLE data.
import UIKit

private let tdMint = UIColor(red: 0.40, green: 0.96, blue: 0.81, alpha: 1)
private let tdPrefs = UserDefaults(suiteName: "com.caun.tdash.amap")!

private func tdLabel(_ size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .white) -> UILabel {
    let label = UILabel()
    label.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.65
    label.layer.shadowColor = UIColor.black.cgColor
    label.layer.shadowOpacity = 0.75
    label.layer.shadowRadius = 2
    label.layer.shadowOffset = CGSize(width: 0, height: 1)
    return label
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
    private let speed = tdLabel(52, weight: .semibold)
    private let unit = tdLabel(10, weight: .medium, color: UIColor.white.withAlphaComponent(0.7))
    private let brand = tdLabel(10, weight: .bold, color: tdMint)
    private let gear = tdLabel(23, weight: .semibold, color: tdMint)
    private let battery = tdLabel(19, weight: .medium)
    private let detail = tdLabel(10, color: UIColor.white.withAlphaComponent(0.85))
    private let state = tdLabel(10, color: UIColor.white.withAlphaComponent(0.75))
    private let batteryIcon = UIImageView(image: UIImage(systemName: "battery.100"))
    private let separator = UIView()
    private let settingsButton = UIButton(type: .system)
    private let meterTrack = UIView()
    private let meterFill = UIView()
    private var timer: Timer?
    private var orientationKey = ""
    private var dragOrigin = CGPoint.zero
    private var trip = TDTripMeter()
    private var collapsed = tdPrefs.bool(forKey: "collapsed")
    private var landscape: Bool { view.bounds.width > view.bounds.height }
    private var lastTelemetryDate: Date?
    weak var hostKeyWindow: UIWindow?

    init(client: TDTeslaClient) { self.client = client; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        panel.layer.cornerRadius = 20
        panel.layer.borderWidth = 0.5
        panel.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowRadius = 8
        panel.layer.shadowOpacity = 0.2
        panel.layer.shadowOffset = CGSize(width: 0, height: 3)
        view.addSubview(panel)
        [speed, unit, brand, gear, battery, detail, state, batteryIcon, separator, settingsButton, meterTrack].forEach(panel.addSubview)
        meterTrack.addSubview(meterFill)
        unit.text = "km/h"; brand.text = "T–DASH  /  BLE"
        batteryIcon.tintColor = tdMint; batteryIcon.contentMode = .scaleAspectFit
        separator.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        meterTrack.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        meterTrack.layer.cornerRadius = 1.5
        meterFill.backgroundColor = tdMint; meterFill.layer.cornerRadius = 1.5
        settingsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        settingsButton.accessibilityLabel = "T-Dash 设置与车辆连接"
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self; panel.addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleCollapsed))
        doubleTap.numberOfTapsRequired = 2; doubleTap.delegate = self; panel.addGestureRecognizer(doubleTap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.65; hold.delegate = self; panel.addGestureRecognizer(hold)
        panel.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "展开或收起仪表", target: self, selector: #selector(accessibilityToggle)),
            UIAccessibilityCustomAction(name: "打开仪表设置", target: self, selector: #selector(accessibilitySettings))
        ]
        client.onChange = { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.15
        refresh()
    }
    deinit { timer?.invalidate() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanel()
    }
    private var safeFrame: CGRect {
        view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 10, dy: 10)
    }
    private func layoutPanel() {
        guard isViewLoaded, view.bounds.width > 0 else { return }
        let safe = safeFrame
        let natural = collapsed ? CGSize(width: 112, height: 66) :
            (landscape ? CGSize(width: 316, height: 110) : CGSize(width: 226, height: 150))
        let size = CGSize(width: min(natural.width, safe.width), height: min(natural.height, safe.height))
        let key = landscape ? "landscape" : "portrait"
        let changed = orientationKey != key || panel.bounds.size != size
        panel.bounds = CGRect(origin: .zero, size: size)
        if changed {
            orientationKey = key
            let x = tdPrefs.object(forKey: "position.\(key).x") as? Double ?? (landscape ? 0.98 : 0.98)
            let y = tdPrefs.object(forKey: "position.\(key).y") as? Double ?? (landscape ? 0.98 : 0.63)
            panel.frame.origin = CGPoint(x: safe.minX + CGFloat(x) * max(0, safe.width - size.width),
                                         y: safe.minY + CGFloat(y) * max(0, safe.height - size.height))
        }
        clampPanel()
        let opacity = tdPrefs.object(forKey: "opacity") as? Double ?? 0.30
        panel.backgroundColor = UIColor(red: 0.035, green: 0.065, blue: 0.08, alpha: CGFloat(max(0, min(0.8, opacity))))
        [brand, gear, battery, detail, state, batteryIcon, separator, meterTrack].forEach { $0.isHidden = collapsed }
        speed.font = .monospacedDigitSystemFont(ofSize: collapsed ? 34 : 52, weight: .semibold)
        if collapsed {
            speed.frame = CGRect(x: 10, y: 5, width: 72, height: 40)
            unit.frame = CGRect(x: 13, y: 45, width: 50, height: 15)
            settingsButton.frame = CGRect(x: size.width - 38, y: 20, width: 38, height: 44)
        } else if landscape {
            brand.frame = CGRect(x: 16, y: 10, width: 180, height: 14)
            speed.frame = CGRect(x: 14, y: 25, width: 107, height: 57)
            unit.frame = CGRect(x: 19, y: 82, width: 50, height: 14)
            separator.frame = CGRect(x: 130, y: 32, width: 0.5, height: 59)
            gear.frame = CGRect(x: 147, y: 31, width: 40, height: 30)
            batteryIcon.frame = CGRect(x: 201, y: 37, width: 22, height: 15)
            battery.frame = CGRect(x: 230, y: 29, width: 68, height: 31)
            detail.frame = CGRect(x: 147, y: 63, width: 153, height: 16)
            state.frame = CGRect(x: 147, y: 83, width: 153, height: 14)
            settingsButton.frame = CGRect(x: size.width - 44, y: 0, width: 44, height: 32)
            meterTrack.frame = CGRect(x: 16, y: 103, width: size.width - 32, height: 3)
        } else {
            brand.frame = CGRect(x: 15, y: 12, width: 170, height: 14)
            speed.frame = CGRect(x: 13, y: 28, width: 117, height: 59)
            unit.frame = CGRect(x: 18, y: 86, width: 50, height: 14)
            separator.frame = CGRect(x: 136, y: 36, width: 0.5, height: 61)
            gear.frame = CGRect(x: 153, y: 32, width: 56, height: 29)
            batteryIcon.frame = CGRect(x: 151, y: 75, width: 19, height: 14)
            battery.frame = CGRect(x: 174, y: 66, width: 46, height: 29)
            detail.frame = CGRect(x: 16, y: 108, width: size.width - 32, height: 15)
            state.frame = CGRect(x: 16, y: 127, width: size.width - 32, height: 13)
            settingsButton.frame = CGRect(x: size.width - 44, y: 0, width: 44, height: 32)
            meterTrack.frame = CGRect(x: 16, y: 145, width: size.width - 32, height: 3)
        }
        let percent = currentBattery ?? 0
        meterFill.frame = CGRect(x: 0, y: 0, width: meterTrack.bounds.width * CGFloat(percent / 100), height: 3)
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
    private var currentBattery: Double? {
        guard client.isConnected, client.batteryUpdatedAt != nil, let value = client.telemetry.batteryPercent,
              value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
    func refresh() {
        guard isViewLoaded else { return }
        let data = client.telemetry
        let liveSpeed = fresh(client.speedUpdatedAt) ? data.speedKph : nil
        if let value = liveSpeed, value.isFinite, (0...350).contains(value) {
            speed.text = String(format: "%.0f", ceil(value))
            speed.textColor = .white
            if let stamp = client.speedUpdatedAt, stamp != lastTelemetryDate {
                trip.ingest(speed: value, at: stamp); lastTelemetryDate = stamp
            }
        } else { speed.text = "—"; speed.textColor = UIColor.white.withAlphaComponent(0.65); trip.interrupt() }
        gear.text = fresh(client.gearUpdatedAt) ? (data.gear ?? "—") : "—"
        let batteryOld = currentBattery != nil && !fresh(client.batteryUpdatedAt, seconds: 45)
        battery.text = currentBattery.map { String(format: "%.0f%%%@", $0, batteryOld ? "*" : "") } ?? "—%"
        batteryIcon.tintColor = (currentBattery ?? 100) < 20 ? .systemOrange : tdMint
        meterFill.backgroundColor = batteryIcon.tintColor
        detail.text = String(format: "本次 ≈ %.1f km  ·  %02d:%02d", trip.distanceKm, Int(trip.activeSeconds) / 60, Int(trip.activeSeconds) % 60)
        state.text = liveSpeed == nil && client.isConnected ? "等待车辆读数 · \(client.status)" : client.status
        if liveSpeed != nil && batteryOld { state.text = "BLE 实时 · *上次驻车电量" }
        speed.accessibilityLabel = liveSpeed == nil ? "车速信号中断" : "车速 \(speed.text ?? "") 公里每小时"
        gear.accessibilityLabel = "挡位 \(gear.text ?? "未知")"
        battery.accessibilityLabel = "车辆电量 \(battery.text ?? "未知")"
        layoutPanel()
        (presentedViewController as? TDSettingsController)?.updateStatus()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { dragOrigin = panel.frame.origin }
        let delta = recognizer.translation(in: view)
        panel.frame.origin = CGPoint(x: dragOrigin.x + delta.x, y: dragOrigin.y + delta.y)
        clampPanel()
        if recognizer.state == .ended || recognizer.state == .cancelled {
            let safe = safeFrame
            tdPrefs.set(Double((panel.frame.minX - safe.minX) / max(1, safe.width - panel.bounds.width)), forKey: "position.\(orientationKey).x")
            tdPrefs.set(Double((panel.frame.minY - safe.minY) / max(1, safe.height - panel.bounds.height)), forKey: "position.\(orientationKey).y")
        }
    }
    @objc private func toggleCollapsed() { collapsed.toggle(); tdPrefs.set(collapsed, forKey: "collapsed"); layoutPanel() }
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) { if recognizer.state == .began { openSettings() } }
    @objc private func accessibilityToggle() -> Bool { toggleCollapsed(); return true }
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
    func setOpacity(_ value: Float) { tdPrefs.set(Double(value), forKey: "opacity"); layoutPanel() }
    func resetTrip() { trip.reset(); lastTelemetryDate = nil; refresh() }
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
        addText("拖动移动位置 · 双击收起或展开 · 长按打开设置\n横屏与竖屏分别记住位置。", size: 12, color: .lightGray)
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
        status.numberOfLines = 0; status.font = .systemFont(ofSize: 13); status.textColor = tdMint
        stack.addArrangedSubview(status)
        addText("先连接，再添加钥匙；按车机提示用实体卡片确认。私钥仅存储于本机钥匙串。", size: 12, color: .lightGray)
        let slider = UISlider()
        slider.minimumValue = 0; slider.maximumValue = 0.8
        slider.value = Float(tdPrefs.object(forKey: "opacity") as? Double ?? 0.30)
        slider.tintColor = tdMint; slider.accessibilityLabel = "仪表底色不透明度"
        slider.addTarget(self, action: #selector(opacityChanged(_:)), for: .valueChanged)
        opacityLabel.font = .systemFont(ofSize: 13); stack.addArrangedSubview(opacityLabel)
        stack.addArrangedSubview(slider); opacityChanged(slider)
        addText("只调节底色，数字始终清晰。0% 为透明底。\n车速与挡位超时 3 秒清空。电量在停车时更新；超过 45 秒标 *，表示上次驻车读数，断连后清空。\n本次里程由有效蓝牙车速积分估算；退到后台或断联期间不计入。", size: 12, color: .lightGray)
        addButton("重置本次行程", action: #selector(resetTrip))
        addButton("断开蓝牙", action: #selector(disconnect))
        addButton("完成", action: #selector(close))
        updateStatus()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboard(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func addText(_ text: String, size: CGFloat, color: UIColor = .white) {
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = .systemFont(ofSize: size); label.textColor = color; stack.addArrangedSubview(label)
    }
    private func addButton(_ text: String, action: Selector) {
        let button = UIButton(type: .system)
        button.setTitle(text, for: .normal); button.tintColor = tdMint
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
    func updateStatus() { status.text = client.status }
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
    @objc private func resetTrip() { dashboard?.resetTrip() }
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
