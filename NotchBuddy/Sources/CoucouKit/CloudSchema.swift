import Foundation

/// The iCloud wire contract between the Mac and the iPhone: the container, the
/// zone both sides write to and the record types. Shared so the two sides can't
/// drift apart. These values are a contract (existing records, subscriptions and
/// the deployed CloudKit schema depend on them): never change one.
enum CloudSchema {
    static let containerID = "iCloud.fr.louisraille.Coucou"
    static let zoneName = "Coucou"

    enum RecordType {
        // Mac → iPhone
        static let session = "Session"
        static let approvalRequest = "ApprovalRequest"
        static let turn = "Turn"
        static let service = "Service"
        static let serviceDetail = "ServiceDetail"
        static let ping = "Ping"
        // iPhone → Mac
        static let decision = "Decision"
        static let answer = "Answer"
        static let instruction = "Instruction"
        static let serviceAction = "ServiceAction"
        static let phoneToken = "PhoneToken"
        static let pong = "Pong"
    }
}
