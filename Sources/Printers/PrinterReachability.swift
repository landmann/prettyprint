import Foundation
import IOBluetooth
import IOKit
import Network

enum PrinterProbeTarget: Equatable {
    case host(String, UInt16)
    case service(name: String, type: String, domain: String)
    case usb(model: String, serial: String?)
    case bluetooth(address: String)
}

enum PrinterReach: Equatable {
    case reachable
    case unreachable
    case localNetworkBlocked
    case unconfirmed

    init(_ confirmed: Bool?) {
        switch confirmed {
        case true?: self = .reachable
        case false?: self = .unreachable
        case nil: self = .unconfirmed
        }
    }
}

enum PrinterReachability {
    static let timeout: TimeInterval = 3

    static func target(forDeviceURI uri: String) -> PrinterProbeTarget? {
        guard let components = URLComponents(string: uri), let scheme = components.scheme?.lowercased() else { return nil }
        let host = components.percentEncodedHost.flatMap { $0.removingPercentEncoding } ?? ""
        switch scheme {
        case "dnssd", "mdns":
            guard let match = host.firstMatch(of: #/^(.+)\.(_[A-Za-z0-9-]+\._(?:tcp|udp))\.(.+?)\.?$/#) else { return nil }
            return .service(name: String(match.1), type: String(match.2), domain: String(match.3))
        case "usb", "ippusb":
            let model = (components.path.removingPercentEncoding ?? components.path)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let serial = components.queryItems?.first { $0.name == "serial" }?.value
            return model.isEmpty && serial == nil ? nil : .usb(model: model, serial: serial)
        case "bluetooth":
            guard host.wholeMatch(of: #/(?:[0-9A-Fa-f]{12}|(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})/#) != nil else { return nil }
            return .bluetooth(address: host)
        default:
            let ports: [String: UInt16] = ["ipp": 631, "ipps": 631, "http": 631, "https": 443, "socket": 9100, "lpd": 515]
            guard let defaultPort = ports[scheme], !host.isEmpty else { return nil }
            return .host(host, components.port.flatMap(UInt16.init(exactly:)) ?? defaultPort)
        }
    }

    static func reach(deviceURI uri: String) async -> PrinterReach {
        switch target(forDeviceURI: uri) {
        case .host(let host, let port):
            guard let port = NWEndpoint.Port(rawValue: port) else { return .unconfirmed }
            return await connects(to: .hostPort(host: NWEndpoint.Host(host), port: port))
        case .service(let name, let type, let domain):
            return await connects(to: .service(name: name, type: type, domain: domain, interface: nil))
        case .usb(let model, let serial):
            return PrinterReach(connectedUSBDevices().contains { $0.matches(model: model, serial: serial) })
        case .bluetooth(let address):
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: PrinterReach(bluetoothIsReachable(address: address)))
                }
            }
        case nil:
            return .unconfirmed
        }
    }

    private static func bluetoothIsReachable(address: String) -> Bool? {
        guard let device = IOBluetoothDevice(addressString: address) else { return nil }
        if device.isConnected() { return true }

        let slotsPerSecond = 1600.0
        let status = device.openConnection(
            nil, withPageTimeout: BluetoothHCIPageTimeout(timeout * slotsPerSecond), authenticationRequired: false
        )
        if status == kIOReturnSuccess {
            device.closeConnection()
            return true
        }
        if status == kIOReturnNotPermitted || status == kIOReturnNotPrivileged { return nil }
        return device.isConnected()
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PrinterReach, Never>?
        private let connection: NWConnection

        init(_ continuation: CheckedContinuation<PrinterReach, Never>, connection: NWConnection) {
            self.continuation = continuation
            self.connection = connection
        }

        func finish(_ result: PrinterReach) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            connection.cancel()
            pending.resume(returning: result)
        }
    }

    private static func connects(to endpoint: NWEndpoint) async -> PrinterReach {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let outcome = Outcome(continuation, connection: connection)
            let queue = DispatchQueue(label: "PrettyPrint.reachability")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: outcome.finish(.reachable)
                case .waiting(let error), .failed(let error):
                    outcome.finish(isPolicyDenied(error) ? .localNetworkBlocked : .unreachable)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { outcome.finish(.unreachable) }
        }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    private struct USBDevice {
        let product: String
        let serial: String?

        func matches(model: String, serial wanted: String?) -> Bool {
            if let wanted { return serial?.caseInsensitiveCompare(wanted) == .orderedSame }
            let modelName = model.split(separator: "/").last.map(String.init) ?? model
            return !modelName.isEmpty && product.localizedCaseInsensitiveContains(modelName)
        }
    }

    private static func connectedUSBDevices() -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var devices: [USBDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            func string(_ key: String) -> String? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            }
            devices.append(USBDevice(product: string("USB Product Name") ?? "", serial: string("USB Serial Number")))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return devices
    }
}
