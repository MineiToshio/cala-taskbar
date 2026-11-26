import Foundation

let commands = ["check", "install", "skip", "later", "dump"]
let arguments = CommandLine.arguments
guard arguments.count == 2, commands.contains(arguments[1]) else {
    let usage = "Usage: swift scripts/update-test-ctl.swift \(commands.joined(separator: "|"))\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("local.cala.test.update"), object: nil,
    userInfo: ["command": arguments[1]], deliverImmediately: true
)
