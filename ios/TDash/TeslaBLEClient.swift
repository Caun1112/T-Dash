// Copyright 2026 T-Dash Authors. SPDX-License-Identifier: Apache-2.0
// iOS CoreBluetooth port of T-Dash's Tesla BLE telemetry transport.
// All state and callbacks stay on the main queue; only read requests are polled.
import Foundation
import CoreBluetooth
import CryptoKit

final class TDTeslaClient: NSObject {
    var onChange: (() -> Void)?
    private(set) var telemetry = TDTelemetry()
    private(set) var status = "点按设置，填写 VIN 后连接车辆"
    private(set) var vin = ""
    /// Authenticated infotainment session. BLE alone does not set this to true.
    private(set) var isConnected = false
    private(set) var isBluetoothConnected = false
    private(set) var isPairing = false
    private(set) var speedUpdatedAt: Date?
    private(set) var batteryUpdatedAt: Date?
    private(set) var rangeUpdatedAt: Date?
    private(set) var gearUpdatedAt: Date?
    private(set) var powerUpdatedAt: Date?
    private(set) var odometerUpdatedAt: Date?

    private static let service = CBUUID(string: "00000211-b2d1-43f0-9b88-960cebf8b91e")
    private static let transmit = CBUUID(string: "00000212-b2d1-43f0-9b88-960cebf8b91e")
    private static let receive = CBUUID(string: "00000213-b2d1-43f0-9b88-960cebf8b91e")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var keyStore: TDKeyStore?
    private var session: TDSession?
    private var decoder = TDFrameDecoder()
    private var partialFrameStarted: Date?
    private var wantedConnection = false
    private var active = true
    private var generation = 0
    private var reconnectAttempts = 0
    private var handshakeAttempts = 0
    private var telemetryFailures = 0
    private var lastChargeRequest = Date.distantPast
    private var pairingDeadline: Date?
    private var expectedName = ""
    private var operationTimeout: DispatchWorkItem?
    private var writeTimeout: DispatchWorkItem?
    private var pollWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var heartbeat: Timer?
#if TDASH_PREVIEW
    private var previewFixtureLoaded = false
#endif

    private enum RequestKind { case session, telemetry }
    private struct PendingRequest {
        let kind: RequestKind
        let request: TDRequest
    }
    private var pending: PendingRequest?
    private var writeFrame: Data?
    private var writeOffset = 0
    private var writeCompletion: (() -> Void)?

    override init() {
        super.init()
        // This timer also refreshes the UI's freshness labels while no packets arrive.
        heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, self.active else { return }
#if TDASH_PREVIEW
            if self.previewFixtureLoaded {
                let now = Date()
                self.speedUpdatedAt = now; self.gearUpdatedAt = now
                self.rangeUpdatedAt = now; self.batteryUpdatedAt = now; self.powerUpdatedAt = now
                self.odometerUpdatedAt = now; self.telemetry.receivedAt = now
            }
#endif
            if let began = self.partialFrameStarted, Date().timeIntervalSince(began) > 5 {
                self.failLink("蓝牙数据帧接收超时，正在重连")
                return
            }
            if let deadline = self.pairingDeadline, Date() >= deadline {
                self.isPairing = false
                self.pairingDeadline = nil
                self.status = "配对确认超时；请在车内刷卡并确认后重试"
            }
            self.onChange?()
        }
        if let heartbeat = heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }

    deinit {
        heartbeat?.invalidate()
        operationTimeout?.cancel()
        writeTimeout?.cancel()
        pollWork?.cancel()
        retryWork?.cancel()
    }

    func connect(vin value: String) {
        precondition(Thread.isMainThread)
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.range(of: "^[A-HJ-NPR-Z0-9]{17}$", options: .regularExpression) != nil else {
            update("请输入 17 位 VIN（不含 I、O、Q）")
            return
        }
        // An injected dylib cannot add a host's privacy usage string. Check before the
        // first CBCentralManager allocation so a missing Info.plist key cannot kill AMap.
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update("此版高德缺少蓝牙权限声明，无法启用车辆连接")
            return
        }
        clearTransport()
        vin = normalized
        do {
            if keyStore == nil { keyStore = try TDKeyStore() }
            expectedName = TDProto.advertisedName(vin: normalized)
        } catch {
            wantedConnection = false
            update("无法读取本机车辆钥匙：\(error.localizedDescription)")
            return
        }
        wantedConnection = true
        reconnectAttempts = 0
        handshakeAttempts = 0
        if !active { update("回到高德后连接车辆"); return }
        update("准备蓝牙连接")
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            handleBluetoothState()
        }
    }

    func disconnect() {
        precondition(Thread.isMainThread)
        wantedConnection = false
        clearTransport()
        update("已断开车辆")
    }

    func setActive(_ value: Bool) {
        precondition(Thread.isMainThread)
        guard value != active else { return }
        active = value
        if !value {
            clearTransport()
            update(wantedConnection ? "后台暂停；回到高德后重连" : "已断开车辆")
        } else if wantedConnection {
            handleBluetoothState()
        }
    }

#if TDASH_PREVIEW
    /// Simulator-only visual fixture; this symbol and data are absent from release builds.
    func loadPreviewFixture() {
        clearTransport()
        previewFixtureLoaded = true
        wantedConnection = false
        isConnected = true
        isBluetoothConnected = true
        let now = Date()
        telemetry.speedKph = 60
        telemetry.rangeKm = 426
        telemetry.batteryPercent = 72
        telemetry.gear = "D"
        telemetry.powerKW = 18
        telemetry.odometerKm = 12486.2
        telemetry.receivedAt = now
        rangeUpdatedAt = now; speedUpdatedAt = now; batteryUpdatedAt = now; gearUpdatedAt = now
        powerUpdatedAt = now; odometerUpdatedAt = now
        update("蓝牙实时 · 预览数据")
    }
#endif

    /// Pairing is only reachable from an explicit UI action, never from reconnect.
    /// The vehicle still requires the physical NFC card/key and its confirmation UI.
    func pair() {
        precondition(Thread.isMainThread)
        guard active, isBluetoothConnected, let keys = keyStore else {
            update("请先连接车辆蓝牙，再点击配对")
            return
        }
        guard !isPairing else { update("请刷 NFC 卡并在车机上确认添加钥匙"); return }
        guard writeFrame == nil else { update("蓝牙正在发送，请稍后再点配对"); return }
        operationTimeout?.cancel()
        pollWork?.cancel()
        retryWork?.cancel()
        pending = nil
        session = nil
        isConnected = false
        clearReadings()
        do {
            let payload = try TDProto.pairingRequest(publicKey: keys.publicKey)
            isPairing = true
            pairingDeadline = Date().addingTimeInterval(90)
            update("请刷 NFC 卡并在车机上确认添加钥匙")
            try sendFrame(payload) { [weak self] in
                self?.scheduleHandshake(after: 3)
            }
            setTimeout(after: 5) { [weak self] in
                self?.failLink("配对请求发送超时，请重新连接")
            }
        } catch {
            isPairing = false
            pairingDeadline = nil
            update("配对请求失败：\(error.localizedDescription)")
        }
    }

    private func update(_ text: String) {
        status = text
        onChange?()
    }

    private func clearReadings() {
        telemetry = TDTelemetry()
        speedUpdatedAt = nil
        batteryUpdatedAt = nil
        rangeUpdatedAt = nil
        gearUpdatedAt = nil
        powerUpdatedAt = nil
        odometerUpdatedAt = nil
    }

    private func clearTransport() {
#if TDASH_PREVIEW
        previewFixtureLoaded = false
#endif
        generation += 1
        operationTimeout?.cancel(); operationTimeout = nil
        writeTimeout?.cancel(); writeTimeout = nil
        pollWork?.cancel(); pollWork = nil
        retryWork?.cancel(); retryWork = nil
        central?.stopScan()
        let old = peripheral
        old?.delegate = nil
        peripheral = nil
        if let old = old { central?.cancelPeripheralConnection(old) }
        tx = nil; rx = nil
        pending = nil; session = nil
        writeFrame = nil; writeOffset = 0; writeCompletion = nil
        decoder.reset(); partialFrameStarted = nil
        isConnected = false; isBluetoothConnected = false
        isPairing = false; pairingDeadline = nil
        lastChargeRequest = .distantPast
        clearReadings()
    }

    private func handleBluetoothState() {
        guard active, wantedConnection, let central = central else { return }
        switch central.state {
        case .poweredOn: startScan()
        case .poweredOff:
            clearTransport()
            update("蓝牙已关闭，请在系统设置中开启")
        case .unauthorized:
            clearTransport()
            update("蓝牙权限未获允许；请在系统设置中允许高德使用蓝牙")
        case .unsupported:
            clearTransport()
            wantedConnection = false
            update("此设备不支持蓝牙低功耗")
        case .resetting:
            clearTransport()
            update("系统蓝牙正在重置")
        case .unknown: update("正在等待系统蓝牙就绪")
        @unknown default: update("系统蓝牙暂不可用")
        }
    }

    private func startScan() {
        guard active, wantedConnection, central?.state == .poweredOn else { return }
        clearTransport()
        handshakeAttempts = 0
        update("正在查找此 VIN 对应的车辆，请靠近车辆")
        // Some Tesla advertisements expose the name and service in separate packets.
        // Match the VIN-derived local name first and then discover the exact GATT service.
        central?.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        setTimeout(after: 15) { [weak self] in
            self?.failLink("未找到车辆；请检查 VIN、蓝牙与车辆唤醒状态")
        }
    }

    private func failLink(_ reason: String) {
        clearTransport()
        update(reason)
        guard active, wantedConnection, central?.state == .poweredOn else { return }
        reconnectAttempts += 1
        let wait = min(30.0, pow(2.0, Double(min(reconnectAttempts, 5))))
        retryWork = schedule(after: wait) { [weak self] in self?.startScan() }
    }

    private func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token, self.active else { return }
            body()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }

    private func setTimeout(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        operationTimeout?.cancel()
        operationTimeout = schedule(after: seconds, body)
    }

    private func scheduleHandshake(after seconds: TimeInterval) {
        operationTimeout?.cancel()
        retryWork?.cancel()
        retryWork = schedule(after: seconds) { [weak self] in self?.beginHandshake() }
    }

    private func beginHandshake() {
        guard active, isBluetoothConnected, pending == nil, writeFrame == nil, let keys = keyStore else { return }
        do {
            session = try TDSession(vin: vin, privateKey: keys.privateKey)
            guard let session = session else { return }
            let request = try session.makeSessionRequest()
            handshakeAttempts += 1
            pending = PendingRequest(kind: .session, request: request)
            if !isPairing { update("正在验证车辆钥匙与加密会话") }
            try sendFrame(request.bytes)
            setTimeout(after: 4) { [weak self] in self?.requestFailed(nil) }
        } catch { requestFailed(error) }
    }

    private func requestFailed(_ error: Error?) {
        let kind = pending?.kind
        pending = nil
        operationTimeout?.cancel()
        // Never interleave a new framed message with a stalled characteristic write.
        guard writeFrame == nil else {
            failLink("蓝牙写入超时，正在重连")
            return
        }
        if kind == .telemetry {
            telemetryFailures += 1
            if telemetryFailures < 3 {
                update("暂未收到车辆数据，正在重试")
                schedulePoll(after: 1)
                return
            }
            isConnected = false
            session = nil
            clearReadings()
            telemetryFailures = 0
            handshakeAttempts = 0
            update("车辆数据中断，正在重新验证连接")
            scheduleHandshake(after: 1)
            return
        }
        isConnected = false
        session = nil
        if isPairing, let deadline = pairingDeadline, Date() < deadline {
            update("等待刷卡和车机确认；正在检查配对结果")
            scheduleHandshake(after: 3)
            return
        }
        if let failure = error as? TDProtocolError {
            switch failure {
            case .keyNotPaired, .vehicleFault(3):
                update("车辆尚未授权这把钥匙，请点击配对并刷 NFC 卡")
                // Keep the GATT connection open so an explicit pair action can use it.
                return
            case .vehicleFault(4), .vehicleFault(7), .vehicleFault(14), .vehicleFault(21):
                let descriptions: [UInt64: String] = [
                    4: "车辆已停用这把钥匙，请检查车机钥匙列表",
                    7: "这把钥匙没有读取权限，请检查车机授权",
                    14: "车辆钥匙已满，请先在车机中移除不再使用的钥匙",
                    21: "车辆移动访问已关闭，请在车机设置中开启"
                ]
                if case .vehicleFault(let code) = failure {
                    update(descriptions[code] ?? failure.localizedDescription)
                }
                return
            default: break
            }
        }
        if handshakeAttempts < 3 {
            update(error?.localizedDescription ?? "车辆会话响应超时，正在重试")
            scheduleHandshake(after: 2)
        } else {
            failLink(error?.localizedDescription ?? "车辆会话响应超时，请确认车辆已唤醒")
        }
    }

    private func schedulePoll(after seconds: TimeInterval) {
        pollWork?.cancel()
        pollWork = schedule(after: seconds) { [weak self] in self?.poll() }
    }

    private func poll() {
        guard isConnected, active, !isPairing, pending == nil, writeFrame == nil,
              let session = session else { return }
        do {
            // Keep each RPC to one category: combined responses can exceed the vehicle's
            // negotiated response MTU. Match Android's policy: slow reads only with fresh
            // parked/neutral gear AND low speed; a stale P must never starve moving speed.
            let now = Date()
            let parked = (telemetry.gear == "P" || telemetry.gear == "N") &&
                now.timeIntervalSince(gearUpdatedAt ?? .distantPast) <= 3 &&
                now.timeIntervalSince(speedUpdatedAt ?? .distantPast) <= 3 &&
                (telemetry.speedKph ?? .infinity) <= 2
            let charge = parked && now.timeIntervalSince(lastChargeRequest) >= 10
            let request = try charge ? session.makeChargeRequest() : session.makeTelemetryRequest()
            if charge { lastChargeRequest = Date() }
            pending = PendingRequest(kind: .telemetry, request: request)
            try sendFrame(request.bytes)
            setTimeout(after: charge ? 2.5 : 4) { [weak self] in self?.requestFailed(nil) }
        } catch { requestFailed(error) }
    }

    private func merge(_ new: TDTelemetry) {
        let now = Date()
        if let value = new.speedKph {
            telemetry.speedKph = value; speedUpdatedAt = now
        }
        if let value = new.rangeKm {
            telemetry.rangeKm = value; rangeUpdatedAt = now
        }
        if let value = new.batteryPercent {
            telemetry.batteryPercent = value; batteryUpdatedAt = now
        }
        if let value = new.gear {
            telemetry.gear = value; gearUpdatedAt = now
        }
        if let value = new.powerKW {
            telemetry.powerKW = value; powerUpdatedAt = now
        }
        if let value = new.odometerKm {
            telemetry.odometerKm = value; odometerUpdatedAt = now
        }
        telemetry.receivedAt = now
    }

    private func acceptFrame(_ data: Data) {
        guard let current = pending, let session = session else { return }
        do {
            // Raw VCSEC pairing acks and other clients' replies do not consume our pending RPC.
            guard try session.matchesResponse(data, request: current.request) else { return }
            switch current.kind {
            case .session:
                try session.acceptSessionResponse(data, request: current.request)
                guard session.isReady else { return }
                pending = nil
                operationTimeout?.cancel()
                isConnected = true
                isPairing = false; pairingDeadline = nil
                handshakeAttempts = 0; reconnectAttempts = 0; telemetryFailures = 0
                update("车辆已授权，正在读取仪表数据")
                schedulePoll(after: 0.1)
            case .telemetry:
                let payload = try session.decryptResponse(data, request: current.request)
                let decoded = try TDProto.parseTelemetry(payload)
                merge(decoded)
                pending = nil
                operationTimeout?.cancel()
                telemetryFailures = 0
                update("车辆蓝牙实时数据")
                // Charging/parked telemetry needs less radio activity than driving.
                schedulePoll(after: telemetry.gear == "P" ? 1.0 : 0.5)
            }
        } catch TDProtocolError.mismatchedResponse {
            return
        } catch TDProtocolError.replay {
            return
        } catch {
            requestFailed(error)
        }
    }

    private func sendFrame(_ body: Data, completion: (() -> Void)? = nil) throws {
        guard writeFrame == nil, tx != nil, let peripheral = peripheral,
              peripheral.state == .connected else {
            throw TDProtocolError.malformed("蓝牙发送通道尚未就绪")
        }
        writeFrame = try TDFrameDecoder.encode(body)
        writeOffset = 0
        writeCompletion = completion
        // Notifications may arrive before the final write ACK. The RPC timeout can
        // already be cancelled then, so the transport needs an independent deadline.
        writeTimeout?.cancel()
        writeTimeout = schedule(after: 5) { [weak self] in
            guard let self = self, self.writeFrame != nil else { return }
            self.failLink("蓝牙写入确认超时，正在重连")
        }
        writeNextChunk()
    }

    private func writeNextChunk() {
        guard let bytes = writeFrame, let peripheral = peripheral, let tx = tx else { return }
        guard writeOffset < bytes.count else {
            writeTimeout?.cancel(); writeTimeout = nil
            writeFrame = nil
            writeOffset = 0
            let completion = writeCompletion
            writeCompletion = nil
            completion?()
            // A notification can precede the final write acknowledgement. If its
            // scheduled poll saw an in-flight frame, restart it now instead of stalling.
            if completion == nil, pending == nil, isConnected { schedulePoll(after: 0.1) }
            return
        }
        let maximum = max(1, peripheral.maximumWriteValueLength(for: .withResponse))
        let end = min(bytes.count, writeOffset + maximum)
        let block = bytes.subdata(in: writeOffset..<end)
        writeOffset = end
        peripheral.writeValue(block, for: tx, type: .withResponse)
    }
}

extension TDTeslaClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, wantedConnection, self.peripheral == nil else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard name == expectedName else { return }
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber,
           !connectable.boolValue { return }
        central.stopScan()
        operationTimeout?.cancel()
        self.peripheral = peripheral
        peripheral.delegate = self
        update("发现车辆，正在连接蓝牙")
        central.connect(peripheral, options: nil)
        setTimeout(after: 20) { [weak self] in self?.failLink("蓝牙连接超时") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, active, wantedConnection else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        update("正在发现车辆蓝牙服务")
        peripheral.discoverServices([Self.service])
        setTimeout(after: 12) { [weak self] in self?.failLink("车辆蓝牙服务初始化超时") }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        failLink("车辆蓝牙连接失败，稍后重试")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        failLink("车辆蓝牙已断开，正在等待重连")
    }
}

extension TDTeslaClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            failLink("未找到 Tesla 车辆蓝牙服务")
            return
        }
        peripheral.discoverCharacteristics([Self.transmit, Self.receive], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral, service.uuid == Self.service else { return }
        guard error == nil,
              let tx = service.characteristics?.first(where: { $0.uuid == Self.transmit }),
              let rx = service.characteristics?.first(where: { $0.uuid == Self.receive }),
              tx.properties.contains(.write), rx.properties.contains(.notify) else {
            failLink("车辆蓝牙读写特征不完整")
            return
        }
        self.tx = tx; self.rx = rx
        // Do not send until didUpdateNotificationState confirms subscription success.
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, characteristic === rx else { return }
        guard error == nil, characteristic.isNotifying else {
            failLink("无法订阅车辆蓝牙通知")
            return
        }
        operationTimeout?.cancel()
        isBluetoothConnected = true
        beginHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === tx, writeFrame != nil else { return }
        guard error == nil else { failLink("蓝牙写入失败，正在重连"); return }
        writeNextChunk()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic === rx else { return }
        guard error == nil, let value = characteristic.value else {
            failLink("车辆蓝牙通知读取失败")
            return
        }
        do {
            let frames = try decoder.append(value)
            if decoder.hasPartialFrame {
                if partialFrameStarted == nil || !frames.isEmpty { partialFrameStarted = Date() }
            } else { partialFrameStarted = nil }
            for frame in frames { acceptFrame(frame) }
        } catch { failLink(error.localizedDescription) }
    }
}
