import CoreBluetooth
import SwiftUI

struct NearbyTracker: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    var strength: String { rssi > -60 ? "Strong signal" : rssi > -80 ? "Moderate signal" : "Weak signal" }
}
@MainActor
final class TrackerScanner: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published var trackers: [NearbyTracker] = []
    @Published var status = "Start scanning to find devices that advertise over Bluetooth."
    @Published var scanning = false
    @Published var selected: UUID?
    var onSignal: ((Int) -> Void)?
    private var central: CBCentralManager?
    private var lastCue = Date.distantPast
    private var expiry: Timer?
    func start() {
        scanning = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { beginIfReady() }
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackers.removeAll { Date().timeIntervalSince($0.lastSeen) > 10 } }
        }
    }
    private func beginIfReady() {
        guard let central, scanning else { return }
        guard central.state == .poweredOn else {
            status = central.state == .unauthorized ? "Bluetooth access denied. Enable it in Settings." : "Bluetooth is unavailable or switched off."
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]); status = "Scanning nearby Bluetooth advertisements…"
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { beginIfReady() }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard rssi < 0, rssi > -120 else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Unnamed Bluetooth device"
        if let index = trackers.firstIndex(where: { $0.id == peripheral.identifier }) {
            trackers[index].rssi = Int(Double(trackers[index].rssi) * 0.65 + Double(rssi) * 0.35); trackers[index].lastSeen = Date()
        } else { trackers.append(NearbyTracker(id: peripheral.identifier, name: name, rssi: rssi, lastSeen: Date())) }
        if selected == peripheral.identifier, Date().timeIntervalSince(lastCue) > 4 {
            lastCue = Date(); onSignal?(rssi > -60 ? 3 : rssi > -80 ? 2 : 1)
        }
    }
    func stop() { scanning = false; central?.stopScan(); expiry?.invalidate(); expiry = nil; status = "Scanning stopped." }
}
