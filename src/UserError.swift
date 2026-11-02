import Foundation

/// What the person can do about an error. Each case maps to one button.
enum Recovery: String {
    case tryAgain, openBluetoothSettings, openPrivacySettings, changePrinter, runSetup, none

    var buttonTitle: String? {
        switch self {
        case .tryAgain: return "Try Again"
        case .openBluetoothSettings: return "Open Bluetooth Settings…"
        case .openPrivacySettings: return "Open Privacy Settings…"
        case .changePrinter: return "Change Printer…"
        case .runSetup: return "Setup Assistant…"
        case .none: return nil
        }
    }
}

/// An error worded for people: a short title, one sentence with the next step,
/// the action that fixes it, and technical details kept for the log.
struct UserError: LocalizedError, CustomStringConvertible {
    let title: String
    let message: String
    let recovery: Recovery
    var details: String? = nil

    var errorDescription: String? { "\(title). \(message)" }
    var description: String { "\(title). \(message)" + (details.map { " [\($0)]" } ?? "") }

    func with(details: String) -> UserError {
        var e = self
        e.details = details
        return e
    }

    static let bluetoothOff = UserError(
        title: "Bluetooth is off",
        message: "Turn on Bluetooth in Control Center, then try again.",
        recovery: .openBluetoothSettings)
    static let bluetoothDenied = UserError(
        title: "MunbynBT can’t use Bluetooth",
        message: "Allow MunbynBT in System Settings › Privacy & Security › Bluetooth.",
        recovery: .openPrivacySettings)
    static let bluetoothUnsupported = UserError(
        title: "This Mac can’t reach the printer",
        message: "It doesn’t support Bluetooth Low Energy. Connect the printer with a USB cable and MUNBYN’s driver instead.",
        recovery: .none)
    static let bluetoothNotReady = UserError(
        title: "Bluetooth isn’t responding",
        message: "Turn Bluetooth off and on in Control Center, then try again.",
        recovery: .tryAgain)
    static let printerNotFound = UserError(
        title: "Printer not found",
        message: "Turn it on and keep it near your Mac. If the MUNBYN app is open on your phone, close it.",
        recovery: .tryAgain)
    static func pairedInSettings(_ name: String) -> UserError {
        UserError(
            title: "Your Mac is paired with the printer",
            message: "Pairing in Bluetooth settings blocks MunbynBT. Remove “\(name)” in System Settings › Bluetooth, then try again.",
            recovery: .openBluetoothSettings)
    }
    static let noResponse = UserError(
        title: "The printer didn’t respond",
        message: "Turn the printer off and on again, then try again.",
        recovery: .tryAgain)
    static let notAPrinter = UserError(
        title: "This isn’t an ITPP130B",
        message: "The selected device can’t print labels. Choose your printer again.",
        recovery: .changePrinter)
    static let interrupted = UserError(
        title: "The label didn’t finish printing",
        message: "The Bluetooth connection dropped. Move the printer closer, then try again.",
        recovery: .tryAgain)
    static let stalled = UserError(
        title: "The label didn’t finish printing",
        message: "Check that labels are loaded and the cover is closed, then try again.",
        recovery: .tryAgain)
    static let unreadable = UserError(
        title: "Can’t print this file",
        message: "MunbynBT prints PDF, PNG and JPEG files.",
        recovery: .none)
    static let emptyPDF = UserError(
        title: "This PDF is empty",
        message: "Download the label again, then print it.",
        recovery: .none)
    static let needsSetup = UserError(
        title: "The printer needs to be set up again",
        message: "Open the Setup Assistant to fix it.",
        recovery: .runSetup)
    static let cancelled = UserError(
        title: "Printing cancelled",
        message: "The rest of the label wasn’t sent.",
        recovery: .none)
    static let printerNotAdded = UserError(
        title: "The printer couldn’t be added",
        message: "macOS didn’t accept it. Try again, or restart your Mac if it keeps failing.",
        recovery: .tryAgain)
}
