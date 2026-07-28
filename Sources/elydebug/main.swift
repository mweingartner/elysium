import Darwin

let exitCode = ElysiumDebugCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
Darwin.exit(exitCode.rawValue)
