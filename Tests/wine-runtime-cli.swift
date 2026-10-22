import Foundation

@main struct RuntimeCLI {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("connect ROOT HELPER | disconnect ROOT | stage INPUT OUTPUT") }
        switch args[1] {
        case "connect":
            guard args.count == 4 else { fatalError("connect ROOT HELPER") }
            try WineRuntimePatch.connect(URL(fileURLWithPath: args[2]), helper: URL(fileURLWithPath: args[3]))
        case "disconnect": try WineRuntimePatch.disconnect(URL(fileURLWithPath: args[2]))
        case "stage":
            guard args.count == 4 else { fatalError("stage INPUT OUTPUT") }
            try WineRuntimePatch.addingDependency(to: Data(contentsOf: URL(fileURLWithPath: args[2])))
                .write(to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
        default: fatalError("Unknown command")
        }
        print("Completed \(args[1])")
    }
}
