enum PrinterSelectionPolicy {
    static func automaticSelection(
        currentPrinter: String,
        printers: [Printer],
        defaultPrinterID: String?,
        hasManualPrinterSelection: Bool
    ) -> String {
        if hasManualPrinterSelection, printers.contains(where: { $0.id == currentPrinter && $0.status.canPrint }) {
            return currentPrinter
        }
        let preferred = printers.filter { $0.id == defaultPrinterID } + printers.filter { $0.id != defaultPrinterID }
        return preferred.first(where: \.status.canPrint)?.id ?? ""
    }
}
