import SwiftUI
import CoreBluetooth

// ActonStatus — a strictly READ-ONLY monitor for the Marshall Acton III.
// It only READS standard Bluetooth characteristics. It never writes to the
// speaker, never touches flash, and never sends control/erase commands.

let SVC_DEVINFO = CBUUID(string: "180A")
let C_MODEL = CBUUID(string: "2A24")
let C_FW    = CBUUID(string: "2A26")
let C_MFG   = CBUUID(string: "2A29")
let SVC_MARSHALL = CBUUID(string: "AA00")
let C_VOL   = CBUUID(string: "AA08") // observed to track volume (read-only here)

final class Model: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Starting…"
    @Published var found = false
    @Published var model = "—"
    @Published var firmware = "—"
    @Published var maker = "—"
    @Published var address = "—"
    @Published var rssi = "—"
    @Published var volume = "—"
    @Published var lastUpdate = "—"

    private var cm: CBCentralManager!
    private var p: CBPeripheral?

    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: nil) }

    func refresh() {
        guard cm.state == .poweredOn else { status = "Bluetooth off"; return }
        model = "—"; firmware = "—"; maker = "—"; volume = "—"
        if let p { cm.cancelPeripheralConnection(p) }
        found = false; status = "Scanning…"
        cm.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if !self.found { self.cm.stopScan(); self.status = "Speaker not found — is it on and in range?" }
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { refresh() }
        else if c.state == .unauthorized { status = "Bluetooth permission denied" }
        else { status = "Bluetooth unavailable" }
    }
    func centralManager(_ c: CBCentralManager, didDiscover per: CBPeripheral, advertisementData a: [String: Any], rssi r: NSNumber) {
        let n = (per.name ?? "") + (a[CBAdvertisementDataLocalNameKey] as? String ?? "")
        guard n.lowercased().contains("acton"), !found else { return }
        found = true; p = per; per.delegate = self; c.stopScan()
        rssi = "\(r) dBm"
        status = "Connecting…"
        c.connect(per)
    }
    func centralManager(_ c: CBCentralManager, didConnect per: CBPeripheral) {
        status = "Connected — reading"; per.readRSSI(); per.discoverServices([SVC_DEVINFO, SVC_MARSHALL])
    }
    func peripheral(_ per: CBPeripheral, didReadRSSI r: NSNumber, error: Error?) { rssi = "\(r) dBm" }
    func peripheral(_ per: CBPeripheral, didDiscoverServices e: Error?) {
        for s in per.services ?? [] { per.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ per: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        for ch in s.characteristics ?? [] where ch.properties.contains(.read) {
            per.readValue(for: ch) // READ ONLY
        }
    }
    func peripheral(_ per: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        guard let v = ch.value else { return }
        let text = String(data: v, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DispatchQueue.main.async {
            switch ch.uuid {
            case C_MODEL: self.model = text
            case C_FW where !text.isEmpty: self.firmware = text
            case C_MFG: self.maker = text
            case C_VOL: self.volume = v.first.map { "\($0)/32" } ?? "—"
            default: break
            }
            self.address = per.identifier.uuidString
            self.status = "Up to date"
            let f = DateFormatter(); f.timeStyle = .medium
            self.lastUpdate = f.string(from: Date())
        }
    }
}

struct Row: View {
    let k: String; let v: String
    var body: some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).fontWeight(.medium).textSelection(.enabled) }
            .font(.system(.body, design: .rounded))
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "hifispeaker.fill").font(.title2)
                VStack(alignment: .leading) {
                    Text("Marshall Acton III").font(.headline)
                    Text(m.status).font(.caption).foregroundStyle(m.found ? .green : .secondary)
                }
                Spacer()
                Circle().fill(m.found ? .green : .gray).frame(width: 10, height: 10)
            }
            Divider()
            Row(k: "Model", v: m.model)
            Row(k: "Firmware", v: m.firmware)
            Row(k: "Maker", v: m.maker)
            Row(k: "Volume", v: m.volume)
            Row(k: "Signal", v: m.rssi)
            Row(k: "Address", v: m.address)
            Divider()
            HStack {
                Text("Updated \(m.lastUpdate)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { m.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
            }
            Text("This app never changes the speaker… but if you want, you can ;p")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 340)
    }
}

@main
struct ActonStatusApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}
