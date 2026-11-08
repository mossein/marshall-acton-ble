import Foundation
import CoreBluetooth

// ActonProbe: scans BLE, finds the Marshall speaker, and dumps its GATT tree.
// Usage: ActonProbe <logPath> [scanSeconds] [nameFilter]
let args = CommandLine.arguments
let logPath = args.count > 1 ? args[1] : NSTemporaryDirectory() + "acton-probe.log"
let scanSeconds = args.count > 2 ? Double(args[2]) ?? 12 : 12
let filter = (args.count > 3 ? args[3] : "acton").lowercased()
let watchSeconds = args.count > 4 ? Double(args[4]) ?? 0 : 0
let t0 = Date()

FileManager.default.createFile(atPath: logPath, contents: nil)
let fh = FileHandle(forWritingAtPath: logPath)!
func log(_ s: String) { let t = String(format: "[%6.1f] ", Date().timeIntervalSince(t0)); fh.write((t + s + "\n").data(using: .utf8)!); try? fh.synchronize() }
func hex(_ d: Data?) -> String { d.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-" }
func props(_ p: CBCharacteristicProperties) -> String {
    var r: [String] = []
    if p.contains(.read) { r.append("read") }
    if p.contains(.write) { r.append("write") }
    if p.contains(.writeWithoutResponse) { r.append("writeNoResp") }
    if p.contains(.notify) { r.append("notify") }
    if p.contains(.indicate) { r.append("indicate") }
    return r.joined(separator: ",")
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!
    var seen: [UUID: CBPeripheral] = [:]
    var targets: [CBPeripheral] = []
    var pendingReads = 0
    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("state=\(c.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        guard c.state == .poweredOn else {
            if c.state == .unauthorized || c.state == .unsupported || c.state == .poweredOff { finish() }
            return
        }
        c.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + scanSeconds) { self.endScan() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        if seen[p.identifier] != nil { return }
        seen[p.identifier] = p
        let local = a[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let svcs = (a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let mfg = hex(a[CBAdvertisementDataManufacturerDataKey] as? Data)
        log("ADV \(p.identifier) name='\(p.name ?? "")' local='\(local)' rssi=\(rssi) svcs=\(svcs) mfg=\(mfg)")
        if (p.name ?? "").lowercased().contains(filter) || local.lowercased().contains(filter) { targets.append(p) }
    }

    func endScan() {
        cm.stopScan()
        log("scan done: \(seen.count) devices, \(targets.count) match '\(filter)'")
        if targets.isEmpty { finish(); return }
        for t in targets { t.delegate = self; cm.connect(t) }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(40, watchSeconds + 20)) { log("timeout"); self.finish() }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { log("CONNECTED \(p.identifier)"); p.discoverServices(nil) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { log("DISCONNECTED \(p.identifier) \(error?.localizedDescription ?? "")") }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { log("CONNECT FAIL \(error?.localizedDescription ?? "")") }

    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        if let e { log("svc err \(e)") }
        for s in p.services ?? [] { log("SERVICE \(s.uuid.uuidString) primary=\(s.isPrimary)"); p.discoverCharacteristics(nil, for: s) }
        if (p.services ?? []).isEmpty { finish() }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        for ch in s.characteristics ?? [] {
            log("  CHAR \(s.uuid.uuidString) / \(ch.uuid.uuidString) [\(props(ch.properties))]")
            p.discoverDescriptors(for: ch)
            if ch.properties.contains(.read) { pendingReads += 1; p.readValue(for: ch) }
            if ch.properties.contains(.notify) && s.uuid.uuidString.count > 4 || s.uuid.uuidString == "AA00" { if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) } }
        }
        scheduleFinish()
    }
    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error e: Error?) {
        for d in ch.descriptors ?? [] { log("    DESC \(ch.uuid.uuidString) / \(d.uuid.uuidString)"); p.readValue(for: d) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor d: CBDescriptor, error e: Error?) {
        log("    DESCVAL \(d.characteristic?.uuid.uuidString ?? "") / \(d.uuid.uuidString) = \(String(describing: d.value ?? "-"))")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        let v = ch.value
        let txt = v.flatMap { String(data: $0, encoding: .utf8) }?.filter { !$0.isNewline } ?? ""
        log("  VALUE \(ch.uuid.uuidString) = \(hex(v)) '\(txt)' \(e.map { "err=\($0.localizedDescription)" } ?? "")")
        pendingReads -= 1; scheduleFinish()
    }
    var finishScheduled = false
    func scheduleFinish() {
        if finishScheduled { return }; finishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(20, watchSeconds)) { self.finish() }
    }
    func finish() { log("END"); for t in targets { cm.cancelPeripheralConnection(t) }; exit(0) }
}

let probe = Probe()
RunLoop.main.run()
