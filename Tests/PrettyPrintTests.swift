import AppKit
import SwiftUI

@main
struct PrettyPrintTests {
    @MainActor
    static func main() {
        runPrinterSelectionPolicyTests()
        runPrintPaperTests()
        runPrinterParsingTests()
        runPrinterSetupTests()
        runDriverFinderTests()

        let popover = makePrettyPrintPopover(
            rootView: EmptyView(),
            onDismiss: {}
        )

        guard popover.behavior == .applicationDefined else {
            fatalError("PrettyPrint popover must not close when the app deactivates")
        }

        let selectedURLs = [
            URL(fileURLWithPath: "/tmp/shipping-label.pdf"),
            URL(fileURLWithPath: "/tmp/return-label.pdf"),
        ]
        let selectedEvents = EventLog()
        let selectedCoordinator = PopoverFilePickerCoordinator(
            presentation: FakePopoverPresentation(events: selectedEvents),
            makePicker: {
                FakeFilePicker(result: .ok(selectedURLs), events: selectedEvents)
            }
        )

        guard selectedCoordinator.chooseFiles() == selectedURLs else {
            fatalError("File picker must return selected URLs in picker order after OK")
        }
        selectedEvents.assertEquals(
            ["close", "activate", "runModal", "show"],
            message: "File picker must close the popover before taking modal input"
        )

        let cancelledEvents = EventLog()
        let cancelledCoordinator = PopoverFilePickerCoordinator(
            presentation: FakePopoverPresentation(events: cancelledEvents),
            makePicker: {
                FakeFilePicker(result: .cancel, events: cancelledEvents)
            }
        )

        guard cancelledCoordinator.chooseFiles().isEmpty else {
            fatalError("Cancelled file picker must return an empty batch")
        }
        cancelledEvents.assertEquals(
            ["close", "activate", "runModal", "show"],
            message: "Cancelled file picker must restore the popover"
        )

        let panel = NSOpenPanel()
        _ = AppKitFilePicker(panel: panel)
        guard panel.allowsMultipleSelection,
              panel.canChooseFiles,
              !panel.canChooseDirectories else {
            fatalError("File picker must allow multiple files and reject directories")
        }

        runPrintInvocationTests()
        runPrintOutcomeTests()
        runPrintQueueCompletionTests()
        runPrintHistoryStoreTests()
        runPointerFocusDismissalTest()

        print("PASS: PrettyPrint popover behavior is applicationDefined")
        print("PASS: file picker returns ordered batches and restores the popover after cancellation")
        print("PASS: AppKit file picker allows multiple file selection")
    }

    @MainActor
    private static func runPointerFocusDismissalTest() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let focusableView = TestFocusableView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(focusableView)

        guard window.makeFirstResponder(focusableView),
              window.firstResponder === focusableView else {
            fatalError("Focus test must establish a first responder")
        }

        PrettyPrintPointerFocus.dismiss(in: window)
        guard window.firstResponder !== focusableView else {
            fatalError("Pointer focus dismissal must clear the clicked control")
        }

        print("PASS: pointer focus dismissal clears the clicked control")
    }

    @MainActor
    private static func runPrintInvocationTests() {
        let files = [
            URL(fileURLWithPath: "/tmp/label one.pdf"),
            URL(fileURLWithPath: "/tmp/label's two.pdf"),
        ]
        let documents = [
            QueuedDocument(fileURL: files[0]),
            QueuedDocument(fileURL: files[1], copies: 3),
        ]

        guard QueuedDocument(fileURL: files[0], copies: 0).copies == 1,
              QueuedDocument(fileURL: files[0], copies: 21).copies == 20 else {
            fatalError("Copy counts must be clamped to the 1-20 range")
        }

        let invocations = PrintBatchCoordinator.invocations(for: documents, printerID: "Office_Laser")
        guard invocations == [
            PrintInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/lp"),
                arguments: ["-d", "Office_Laser", "-n", "1", "-o", "sides=one-sided", "/tmp/label one.pdf"]
            ),
            PrintInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/lp"),
                arguments: ["-d", "Office_Laser", "-n", "3", "-o", "sides=one-sided", "/tmp/label's two.pdf"]
            ),
        ] else {
            fatalError("Print invocations must preserve order, paths, and copy counts")
        }

        print("PASS: print invocations preserve batch order without shell interpolation")
    }

    @MainActor
    private static func runPrintOutcomeTests() {
        let files = [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
            URL(fileURLWithPath: "/tmp/c.pdf"),
        ]
        let simulatedOutcomes = [true, false, true]
        var nextOutcomeIndex = 0
        var receivedResult: PrintBatchResult?

        PrintBatchCoordinator.submit(
            files,
            printerID: "Office_Laser",
            runner: { _, completion in
                let outcome = simulatedOutcomes[nextOutcomeIndex]
                nextOutcomeIndex += 1
                completion(outcome)
            }
        ) { result in
            receivedResult = result
        }

        let expectedResults = zip(files, [1, 0, 0]).map {
            PrintDocumentResult(fileURL: $0, requestedCopies: 1, submittedCopies: $1)
        }
        guard receivedResult == PrintBatchResult(documentResults: expectedResults),
              nextOutcomeIndex == 2,
              receivedResult?.succeeded == 1,
              receivedResult?.failed == 2 else {
            fatalError("A failed submission must stop the batch and leave later documents unsent")
        }

        print("PASS: a failed submission stops the batch in order")
    }

    private static func runPrintQueueCompletionTests() {
        let duplicateURL = URL(fileURLWithPath: "/tmp/duplicate.pdf")
        let successful = QueuedDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            fileURL: duplicateURL
        )
        let failed = QueuedDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            fileURL: URL(fileURLWithPath: "/tmp/failed.pdf")
        )
        let laterDuplicate = QueuedDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            fileURL: duplicateURL
        )
        let submitted = [successful, failed]
        let currentQueue = [successful, failed, laterDuplicate]

        let mixed = reducePrintQueueCompletion(
            submitted: submitted,
            currentQueue: currentQueue,
            submittedCopies: [1, 0]
        )
        guard mixed.remainingQueue == [failed, laterDuplicate],
              mixed.successfulDocuments == [successful] else {
            fatalError("Mixed print outcomes must remove only successful submitted IDs")
        }

        let allSucceeded = reducePrintQueueCompletion(
            submitted: submitted,
            currentQueue: submitted,
            submittedCopies: [1, 1]
        )
        guard allSucceeded.remainingQueue.isEmpty,
              allSucceeded.successfulDocuments == submitted else {
            fatalError("All-success completion must clear the submitted queue")
        }

        let allFailed = reducePrintQueueCompletion(
            submitted: submitted,
            currentQueue: submitted,
            submittedCopies: [0, 0]
        )
        guard allFailed.remainingQueue == submitted,
              allFailed.successfulDocuments.isEmpty else {
            fatalError("All-failure completion must leave the submitted queue unchanged")
        }

        let mismatched = reducePrintQueueCompletion(
            submitted: submitted,
            currentQueue: currentQueue,
            submittedCopies: [1]
        )
        guard mismatched.remainingQueue == currentQueue,
              mismatched.successfulDocuments.isEmpty else {
            fatalError("Mismatched print outcomes must fail closed")
        }

        print("PASS: queue reconciliation handles partial results, duplicates, and later additions")
    }

    private static func runPrintHistoryStoreTests() {
        let suiteName = "io.github.landmann.prettyprint.tests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated print-history defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("invalid history".utf8), forKey: PrintHistoryStore.storageKey)
        guard PrintHistoryStore(defaults: defaults).records.isEmpty else {
            fatalError("Corrupt print history must recover as empty")
        }
        defaults.removeObject(forKey: PrintHistoryStore.storageKey)

        let fileURLs = (1...6).map {
            URL(fileURLWithPath: "/tmp/document-\($0).pdf")
        }
        let printDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = PrintHistoryStore(defaults: defaults)
        store.recordSuccessfulPrints(fileURLs, printedAt: printDate)

        let expectedURLs = Array(fileURLs.reversed().prefix(5))
        guard store.records.map(\.fileURL) == expectedURLs,
              store.records.allSatisfy({ $0.printedAt == printDate }) else {
            fatalError("Print history must keep the five newest completed documents")
        }

        let reloadedStore = PrintHistoryStore(defaults: defaults)
        guard reloadedStore.records == store.records else {
            fatalError("Print history must persist across store instances")
        }

        print("PASS: print history persists the five newest successful documents")
    }

    private static func runPrintPaperTests() {
        guard PrintPaper(pageSizeName: "A4") == .a4,
              PrintPaper(pageSizeName: "Letter.Borderless") == .letter,
              PrintPaper(pageSizeName: "w288h432")?.size == CGSize(width: 288, height: 432),
              PrintPaper(pageSizeName: "4x6")?.size == CGSize(width: 288, height: 432),
              PrintPaper(pageSizeName: "55x91mm")?.size == CGSize(width: 156, height: 258),
              PrintPaper(pageSizeName: "55x91mm")?.usesInches == false,
              PrintPaper(pageSizeName: "na_letter_8.5x11in")?.size == CGSize(width: 612, height: 792),
              PrintPaper(pageSizeName: "iso_a5_148x210mm")?.size == CGSize(width: 420, height: 595),
              PrintPaper(pageSizeName: "EnvChou3") == nil else {
            fatalError("CUPS page size names must map to paper sizes")
        }

        let paper = PrintPaper(pageSizeName: "w288h432")!
        let single = PrintComposition.single(
            sourceURL: URL(fileURLWithPath: "/tmp/wide.pdf"),
            sourceAspect: 2,
            paper: paper
        )
        let fitted = single.items[0].frame
        guard abs(fitted.width - paper.size.width) < 0.001,
              abs(fitted.width / fitted.height - 2) < 0.001,
              abs(fitted.midY - paper.size.height / 2) < 0.001 else {
            fatalError("A new composition must fit the source on the paper, centered")
        }

        let frame = CGRect(x: 10, y: 10, width: 100, height: 50)
        let locked = PrintCompositionGeometry.resized(
            frame,
            corner: .bottomRight,
            to: CGPoint(x: 210, y: 30),
            lockedRatio: 2
        )
        guard locked.origin == frame.origin,
              locked.width == 200,
              locked.height == 100 else {
            fatalError("Locked resize must keep the ratio and the opposite corner")
        }

        let free = PrintCompositionGeometry.resized(
            frame,
            corner: .topLeft,
            to: CGPoint(x: 100, y: 0),
            lockedRatio: nil
        )
        guard free.maxX == frame.maxX,
              free.maxY == frame.maxY,
              free.width == 12,
              free.height == 60 else {
            fatalError("Free resize must clamp to the minimum side and keep the opposite corner")
        }

        let snap = PrintCompositionGeometry.snapped(
            CGRect(x: 92, y: 3, width: 100, height: 40),
            paper: paper.size,
            threshold: 4
        )
        guard snap.frame.midX == paper.size.width / 2,
              snap.frame.minY == 0,
              snap.guides == PrintSnapGuides(vertical: paper.size.width / 2, horizontal: 0) else {
            fatalError("Moving near the paper center or edge must snap and show guides")
        }

        let square = PrintCompositionGeometry.applying(
            ratio: 1,
            to: CGRect(x: 0, y: 0, width: 200, height: 50),
            paper: paper.size
        )
        guard abs(square.width - 100) < 0.001,
              abs(square.height - 100) < 0.001,
              abs(square.midX - 100) < 0.001 else {
            fatalError("Changing the aspect ratio must keep the area and center")
        }

        let onA4 = single.adapted(to: .a4)
        guard onA4.paper == .a4,
              abs(onA4.items[0].frame.width / onA4.items[0].frame.height - 2) < 0.001 else {
            fatalError("Switching paper must scale items without distorting them")
        }

        let rotatedFit = PrintCompositionGeometry.fitted(aspect: 2, rotation: 90, in: paper.bounds)
        let rotatedBounds = PrintCompositionGeometry.boundingBox(of: rotatedFit, rotation: 90)
        guard abs(rotatedBounds.height - paper.size.height) < 0.001 || abs(rotatedBounds.width - paper.size.width) < 0.001,
              rotatedBounds.width <= paper.size.width + 0.001,
              rotatedBounds.height <= paper.size.height + 0.001,
              rotatedFit.width > rotatedFit.height else {
            fatalError("Fitting a rotated item must fit its rotated outline on the paper")
        }

        let tilted = CGRect(x: 50, y: 50, width: 100, height: 40)
        let anchorBefore = PrintCompositionGeometry.corner(.topLeft, of: tilted, rotation: 30)
        let dragTarget = PrintCompositionGeometry.rotate(
            CGPoint(x: 180, y: 110),
            around: CGPoint(x: tilted.midX, y: tilted.midY),
            degrees: 30
        )
        let tiltedResize = PrintCompositionGeometry.resized(
            tilted,
            corner: .bottomRight,
            to: dragTarget,
            lockedRatio: nil,
            rotation: 30
        )
        let anchorAfter = PrintCompositionGeometry.corner(.topLeft, of: tiltedResize, rotation: 30)
        guard abs(anchorAfter.x - anchorBefore.x) < 0.001,
              abs(anchorAfter.y - anchorBefore.y) < 0.001,
              abs(tiltedResize.width - 130) < 0.001,
              abs(tiltedResize.height - 60) < 0.001 else {
            fatalError("Resizing a rotated item must keep the opposite corner fixed on the paper")
        }

        guard PrintCompositionGeometry.normalized(degrees: -90) == 270,
              PrintCompositionGeometry.normalized(degrees: 450) == 90 else {
            fatalError("Rotation must normalize into 0..<360")
        }

        print("PASS: composition geometry fits, resizes, snaps, reshapes, rotates, and adapts to paper")
    }

    private static func runPrinterSelectionPolicyTests() {
        let office = Printer(id: "Office", name: "Office", status: .offline)
        let label = Printer(id: "Label", name: "Label", status: .ready)
        let home = Printer(id: "Home", name: "Home", status: .ready)

        func select(_ printers: [Printer], current: String = "", defaultID: String? = "Office", manual: Bool = false) -> String {
            PrinterSelectionPolicy.automaticSelection(
                currentPrinter: current,
                printers: printers,
                defaultPrinterID: defaultID,
                hasManualPrinterSelection: manual
            )
        }

        let onlineDefault = Printer(id: "Office", name: "Office", status: .ready)
        guard select([label, onlineDefault]) == "Office",
              select([office, label, home]) == "Label",
              select([office, Printer(id: "Label", name: "Label", status: .unavailable)]) == "",
              select([], current: "Gone") == "",
              select([onlineDefault, label], current: "Label", manual: true) == "Label",
              select([office, label], current: "Office", manual: true) == "Label",
              select([office, label], current: "Removed", manual: true) == "Label",
              select([office, label], defaultID: nil) == "Label",
              !PrinterStatus.unavailable.canPrint, PrinterStatus.unavailable.title == "Not available" else {
            fatalError("Selection must pick an available printer and select none when none is available")
        }

        guard PrinterReachability.target(forDeviceURI: "ipp://100E73000000.local:631/ipp/print") == .host("100E73000000.local", 631),
              PrinterReachability.target(forDeviceURI: "ipps://printer.example") == .host("printer.example", 631),
              PrinterReachability.target(forDeviceURI: "socket://192.168.1.20") == .host("192.168.1.20", 9100),
              PrinterReachability.target(forDeviceURI: "lpd://10.0.0.5/queue") == .host("10.0.0.5", 515),
              PrinterReachability.target(forDeviceURI: "dnssd://Brother%20HL-L2350DW%20series._ipp._tcp.local./?uuid=1234")
                == .service(name: "Brother HL-L2350DW series", type: "_ipp._tcp", domain: "local"),
              PrinterReachability.target(forDeviceURI: "usb://Brother/QL-820NWB?serial=000G1Z123456")
                == .usb(model: "QL-820NWB", serial: "000G1Z123456"),
              PrinterReachability.target(forDeviceURI: "bluetooth://001122334455") == nil,
              PrinterReachability.target(forDeviceURI: "smb://server/printer") == nil else {
            fatalError("Device URIs must map to the right reachability check")
        }

        print("PASS: selection prefers an available default, keeps an available manual pick, and selects none when nothing is available")
    }

    private static func runPrinterParsingTests() {
        let options = PrinterDirectory.parseOptions(
            "copies=1 printer-info='Canon G3010 series' printer-is-accepting-jobs=true printer-state=3 "
                + "printer-state-reasons=none printer-uri-supported=ipp://localhost/printers/Canon_G3010 "
                + "printer-location=\"Front desk\" note=it\\'s"
        )
        guard options["printer-info"] == "Canon G3010 series",
              options["printer-location"] == "Front desk",
              options["note"] == "it's",
              PrinterDirectory.status(queue: "Canon_G3010", options: options) == .ready,
              PrinterDirectory.status(queue: "Other", options: options) == .unavailable else {
            fatalError("lpoptions output must parse quoted values and printer state")
        }

        var reasons = options
        reasons["printer-state-reasons"] = "media-empty-error"
        guard PrinterDirectory.status(queue: "Canon_G3010", options: reasons) == .paperNeeded else {
            fatalError("Empty media must report paper needed")
        }

        guard PrinterDirectory.defaultPrinterID(inLpstatOutput: "system default destination: Canon_G3010\n") == "Canon_G3010",
              PrinterDirectory.defaultPrinterID(inLpstatOutput: "no system default destination\n") == nil else {
            fatalError("lpstat -d output must yield the default queue")
        }

        let capabilities = PrinterDirectory.capabilities(inOptions: """
        PageSize/Media Size: 4x6 Letter *A4 A5
        Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble
        """)
        guard capabilities.paper == .a4, capabilities.sides == PrintSides.allCases else {
            fatalError("lpoptions -l output must yield the default paper and duplex modes")
        }
        guard PrinterDirectory.capabilities(inOptions: "sides/Sides: *one-sided").sides == [.oneSided] else {
            fatalError("Printers without duplex must only offer one-sided printing")
        }

        print("PASS: CUPS printer options, status, default queue, paper, and duplex parse")
    }

    private static func runPrinterSetupTests() {
        let devices = PrinterSetup.parseDevices("""
        Device: uri = ipp
                class = network
                info = Internet Printing Protocol (ipp)
                make-and-model = Unknown
                device-id = 
        Device: uri = dnssd://Brother%20HL-L2350DW._ipp._tcp.local./?uuid=1234
                class = network
                info = Brother HL-L2350DW
                make-and-model = Brother HL-L2350DW series
                device-id = MFG:Brother;MDL:HL-L2350DW;
        Device: uri = usb://Zebra/ZD420?serial=1
                class = direct
                info = Zebra ZD420
                make-and-model = Unknown
                device-id = MFG:Zebra;MDL:ZD420;
        """)
        guard devices.count == 2,
              devices[0].isNetwork, devices[0].isDriverless,
              devices[0].name == "Brother HL-L2350DW",
              devices[0].deviceID == "MFG:Brother;MDL:HL-L2350DW;",
              !devices[1].isNetwork, !devices[1].isDriverless,
              devices[1].model == "Zebra ZD420" else {
            fatalError("lpinfo output must yield real devices with their setup route")
        }

        guard PrinterSetup.configuredDeviceURIs(inLpstatOutput: "device for Canon_G3010: ipp://printer.local:631/ipp/print\n")
                == ["ipp://printer.local:631/ipp/print"] else {
            fatalError("lpstat -v output must yield configured device URIs")
        }

        guard PrinterSetup.queueName(for: "Brother HL-L2350DW (Office)", existing: []) == "Brother_HL-L2350DW_Office",
              PrinterSetup.queueName(for: "Zebra", existing: ["Zebra", "Zebra_2"]) == "Zebra_3",
              PrinterSetup.queueName(for: "Office", existing: ["office"]) == "Office_2",
              PrinterSetup.queueName(for: "日本", existing: []) == "Printer" else {
            fatalError("Queue names must be ASCII, readable, and unique")
        }

        print("PASS: printer discovery output, configured URIs, and queue names parse")
    }

    private static func runDriverFinderTests() {
        let answer = """
        I found it. {"found": true, "vendor": "Brother", "driverName": "Printer Driver {CUPS}",         "pageURL": "https://support.brother.com/g/b/downloadlist.aspx",         "packageURL": "http://example.com/driver.pkg", "notes": "Use \\"Add\\" after installing."}
        """
        guard let suggestion = DriverFinder.parse(answer),
              suggestion.driverName == "Printer Driver {CUPS}",
              suggestion.packageURL == nil,
              suggestion.notes == "Use \"Add\" after installing." else {
            fatalError("Driver answers must parse from surrounding text and drop non-https packages")
        }
        guard DriverFinder.parse(#"{"found": true, "vendor": "X", "driverName": "Y", "pageURL": "http://x", "packageURL": null, "notes": ""}"#) == nil,
              DriverFinder.parse("No JSON here") == nil else {
            fatalError("Driver answers without an https page must be rejected")
        }
        guard DriverFinderKey.provider(for: "sk-ant-api03-abc") == .anthropic,
              DriverFinderKey.provider(for: "sk-proj-abc") == .openAI else {
            fatalError("API keys must map to their provider")
        }

        let gatekeeper = """
        /Volumes/Driver/Start Here Mac.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: Brother Industries, LTD. (5HCL85FLGW)
        """
        let unnotarized = """
        /Volumes/Driver/Driver.pkg: accepted
        source=Developer ID
        origin=Developer ID Installer: Someone (ABCDE12345)
        """
        let spoofed = """
        /Volumes/Driver/x
        origin=Developer ID Application: Brother Industries, LTD. (5HCL85FLGW)
        y.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: Someone Else (ABCDE12345)
        """
        guard DriverInstaller.identity(inGatekeeperOutput: gatekeeper) == "Developer ID Application: Brother Industries, LTD. (5HCL85FLGW)",
              DriverInstaller.displayName(of: "Developer ID Application: Brother Industries, LTD. (5HCL85FLGW)") == "Brother Industries, LTD.",
              DriverInstaller.identity(inGatekeeperOutput: spoofed) == nil,
              DriverInstaller.isSafePath("/Volumes/Driver/Start Here Mac.app"),
              !DriverInstaller.isSafePath("/Volumes/Driver/x\u{2028}source=Notarized Developer ID.app"),
              !DriverInstaller.isSafePath("/Volumes/Driver/x\u{2029}y.pkg"),
              !DriverInstaller.isSafePath("/Volumes/Driver/x\ny.pkg"),
              !DriverInstaller.isSafePath("/Volumes/Driver/x\u{0085}y.pkg"),
              DriverInstaller.identity(inGatekeeperOutput: unnotarized) == nil,
              DriverInstaller.identity(inGatekeeperOutput: "/x.app: rejected\nsource=no usable signature") == nil else {
            fatalError("Installers must pass Gatekeeper as notarized Developer ID software")
        }
        guard DriverInstaller.archiveFitsLimits(zipinfoTotals: "Archive:  d.zip\n3 files, 52428800 bytes uncompressed, 20971520 bytes compressed:  60.0%"),
              !DriverInstaller.archiveFitsLimits(zipinfoTotals: "2 files, 9000000000 bytes uncompressed, 1000 bytes compressed:  99.9%"),
              !DriverInstaller.archiveFitsLimits(zipinfoTotals: "30000 files, 1000 bytes uncompressed, 900 bytes compressed:  10.0%"),
              !DriverInstaller.archiveFitsLimits(zipinfoTotals: "garbage") else {
            fatalError("ZIP archives must stay within the entry and size limits")
        }

        print("PASS: driver answers, API key providers, Gatekeeper verdicts, and archive limits parse")
    }
}

private final class TestFocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class EventLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func assertEquals(_ expected: [String], message: String) {
        guard events == expected else {
            fatalError("\(message): expected \(expected), got \(events)")
        }
    }
}

@MainActor
private final class FakePopoverPresentation: PopoverFilePickerPresentation {
    private let events: EventLog

    init(events: EventLog) {
        self.events = events
    }

    func closePopover() {
        events.append("close")
    }

    func activateApplication() {
        events.append("activate")
    }

    func showPopover() {
        events.append("show")
    }
}

@MainActor
private final class FakeFilePicker: FilePicking {
    private let result: FilePickerResponse
    private let events: EventLog

    init(result: FilePickerResponse, events: EventLog) {
        self.result = result
        self.events = events
    }

    func runModal() -> FilePickerResponse {
        events.append("runModal")
        return result
    }
}
