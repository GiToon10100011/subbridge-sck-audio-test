import Foundation

setlinebuf(stdout)

let status = await CLI.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
