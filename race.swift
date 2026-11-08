import Foundation
import CoreBluetooth

// ActonRace: talks the Airoha RACE protocol to the speaker over BLE GATT.
// READ-ONLY by default: sends only query commands and prints replies.
// Usage: ActonRace <logPath> [scanSeconds]

let args = CommandLine.arguments
let logPath = args.count > 1 ? args[1] : NSTemporaryDirectory() + "acton-race.log"
let scanSeconds = args.count > 2 ? Double(args[2]) ?? 12 : 12

FileManager.default.createFile(atPath: logPath, contents: nil)
let fh = FileHandle(forWritingAtPath: logPath)!
let t0 = Date()
func log(_ s: String) { let t = String(format: "[%6.2f] ", Date().timeIntervalSince(t0)); fh.write((t + s + "\n").data(using: .utf8)!); try? fh.synchronize() }
func hex(_ d: Data?) -> String { d.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-" }

// RACE service + characteristics (from public race-toolkit; matched our probe)
let SVC  = CBUUID(string: "5052494D-2DAB-0341-6972-6F6861424C45")
let TX   = CBUUID(string: "43484152-2DAB-3241-6972-6F6861424C45") // write
let RX   = CBUUID(string: "43484152-2DAB-3141-6972-6F6861424C45") // notify

func raceCmd(id: UInt16, payload: [UInt8] = [], head: UInt8 = 0x05, type: UInt8 = 0x5A) -> Data {
    let length = UInt16(payload.count + 2) // cmd id (2) + payload
    var d = Data([head, type])
    d.append(UInt8(length & 0xff)); d.append(UInt8(length >> 8))
    d.append(UInt8(id & 0xff)); d.append(UInt8(id >> 8))
    d.append(contentsOf: payload)
    return d
}

// READ-ONLY queries only.
struct Q { let name: String; let data: Data }
let queries: [Q] = [
    Q(name: "GetSDKInfo(0x0301)",     data: raceCmd(id: 0x0301)),
    Q(name: "BuildVersion(0x1E08)",   data: raceCmd(id: 0x1E08)),
    Q(name: "GetBDAddress(0x0CD5)",   data: raceCmd(id: 0x0CD5)),
    // NOTE: GetLinkKey(0x0CC0) is deliberately omitted — its reply contains
    // the Bluetooth pairing link keys (cryptographic secrets).
]

final class R: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!
    var periph: CBPeripheral?
    var tx: CBCharacteristic?
    var qi = 0
    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("state=\(c.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        guard c.state == .poweredOn else { if c.state.rawValue >= 3 { finish() }; return }
        c.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + scanSeconds) {
            if self.periph == nil { log("speaker not found"); self.finish() }
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        let n = (p.name ?? "") + (a[CBAdvertisementDataLocalNameKey] as? String ?? "")
        if n.lowercased().contains("acton") && periph == nil {
            periph = p; p.delegate = self; cm.stopScan(); log("found \(n) rssi=\(rssi)"); cm.connect(p)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { log("connected"); p.discoverServices([SVC]) }
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == SVC }) else { log("RACE service missing"); finish(); return }
        p.discoverCharacteristics([TX, RX], for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == TX { tx = ch }
            if ch.uuid == RX { p.setNotifyValue(true, for: ch) }
        }
        log("ready: tx=\(tx != nil)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.next() }
    }
    func next() {
        guard qi < queries.count, let tx, let p = periph else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { log("all queries done"); self.finish() }
            return
        }
        let q = queries[qi]; qi += 1
        log("--> \(q.name): \(hex(q.data))")
        p.writeValue(q.data, for: tx, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.next() } // pace queries
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error e: Error?) {
        if let e { log("write err \(e.localizedDescription)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        guard let v = ch.value else { return }
        log("<-- RX \(hex(v))")
        decode(v)
    }
    func decode(_ v: Data) {
        guard v.count >= 6 else { return }
        let b = [UInt8](v)
        let id = UInt16(b[4]) | (UInt16(b[5]) << 8)
        if id == 0x0CC0 && v.count >= 9 {
            let count = b[7] // reserved,num_of_devices,reserved
            log("    *** GetLinkKey: bonded device count = \(count) ***")
        }
        if id == 0x0CD5 && v.count >= 8 {
            let addr = Array(b[8...]).reversed().map { String(format: "%02x", $0) }.joined(separator: ":")
            log("    *** speaker BD_ADDR = \(addr) ***")
        }
    }
    func finish() { if let p = periph { cm.cancelPeripheralConnection(p) }; log("END"); exit(0) }
}
let r = R(); RunLoop.main.run()
