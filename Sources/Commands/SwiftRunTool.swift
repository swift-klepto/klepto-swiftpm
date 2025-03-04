/*
This source file is part of the Swift.org open source project

Copyright 2015 - 2016 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import ArgumentParser
import TSCBasic
import Build
import TSCUtility
import PackageGraph
import PackageModel

/// An enumeration of the errors that can be generated by the run tool.
private enum RunError: Swift.Error {
    /// The package manifest has no executable product.
    case noExecutableFound

    /// Could not find a specific executable in the package manifest.
    case executableNotFound(String)

    /// There are multiple executables and one must be chosen.
    case multipleExecutables([String])
}

extension RunError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noExecutableFound:
            return "no executable product available"
        case .executableNotFound(let executable):
            return "no executable product named '\(executable)'"
        case .multipleExecutables(let executables):
            let joinedExecutables = executables.joined(separator: ", ")
            return "multiple executable products available: \(joinedExecutables)"
        }
    }
}

struct RunToolOptions: ParsableArguments {
    enum RunMode {
        case repl
        case run
    }

    /// Returns the mode in with the tool command should run.
    var mode: RunMode {
        if shouldLaunchREPL {
            return .repl
        }
        return .run
    }
    
    /// If the executable product should be built before running.
    @Flag(name: .customLong("skip-build"), help: "Skip building the executable product")
    var shouldSkipBuild: Bool = false
    
    var shouldBuild: Bool { !shouldSkipBuild }

    /// If the test should be built.
    @Flag(name: .customLong("build-tests"), help: "Build both source and test targets")
    var shouldBuildTests: Bool = false

    /// If should launch the Swift REPL.
    @Flag(name: .customLong("repl"), help: "Launch Swift REPL for the package")
    var shouldLaunchREPL: Bool = false

    /// The executable product to run.
    @Argument(help: "The executable to run", completion: .shellCommand("swift package completion-tool list-executables"))
    var executable: String?

    /// The arguments to pass to the executable.
    @Argument(parsing: .unconditionalRemaining,
              help: "The arguments to pass to the executable")
    var arguments: [String] = []
}

/// swift-run tool namespace
public struct SwiftRunTool: SwiftCommand {
    public static var configuration = CommandConfiguration(
        commandName: "run",
        _superCommandName: "swift",
        abstract: "Build and run an executable product",
        discussion: "SEE ALSO: swift build, swift package, swift test",
        version: Versioning.currentVersion.completeDisplayString,
        helpNames: [.short, .long, .customLong("help", withSingleDash: true)])

    @OptionGroup()
    public var swiftOptions: SwiftToolOptions

    @OptionGroup()
    var options: RunToolOptions

    public func run(_ swiftTool: SwiftTool) throws {
        if options.shouldBuildTests && options.shouldSkipBuild {
            swiftTool.diagnostics.emit(
              .mutuallyExclusiveArgumentsError(arguments: ["--build-tests", "--skip-build"]))
            throw ExitCode.failure
        }

        switch options.mode {
        case .repl:
            // Load a custom package graph which has a special product for REPL.
            let graphLoader = {
                try swiftTool.loadPackageGraph(
                    explicitProduct: self.options.executable,
                    createREPLProduct: self.options.shouldLaunchREPL)
            }
            let buildParameters = try swiftTool.buildParameters()

            // Construct the build operation.
            let buildOp = BuildOperation(
                buildParameters: buildParameters,
                cacheBuildManifest: false,
                packageGraphLoader: graphLoader,
                diagnostics: swiftTool.diagnostics,
                stdoutStream: swiftTool.stdoutStream
            )

            // Save the instance so it can be cancelled from the int handler.
            swiftTool.buildSystemRef.buildSystem = buildOp

            // Perform build.
            try buildOp.build()

            // Execute the REPL.
            let arguments = buildOp.buildPlan!.createREPLArguments()
            print("Launching Swift REPL with arguments: \(arguments.joined(separator: " "))")
            try run(
                swiftTool.getToolchain().swiftInterpreter,
                originalWorkingDirectory: swiftTool.originalWorkingDirectory,
                arguments: arguments)

        case .run:
            // Detect deprecated uses of swift run to interpret scripts.
            if let executable = options.executable, isValidSwiftFilePath(executable) {
                swiftTool.diagnostics.emit(.runFileDeprecation)
                // Redirect execution to the toolchain's swift executable.
                let swiftInterpreterPath = try swiftTool.getToolchain().swiftInterpreter
                // Prepend the script to interpret to the arguments.
                let arguments = [executable] + options.arguments
                try run(
                    swiftInterpreterPath,
                    originalWorkingDirectory: swiftTool.originalWorkingDirectory,
                    arguments: arguments)
                return
            }

            // Redirect stdout to stderr because swift-run clients usually want
            // to ignore swiftpm's output and only care about the tool's output.
            swiftTool.redirectStdoutToStderr()
            
            do {
                let buildSystem = try swiftTool.createBuildSystem(explicitProduct: options.executable)
                let productName = try findProductName(in: buildSystem.getPackageGraph())
                if options.shouldBuildTests {
                    try buildSystem.build(subset: .allIncludingTests)
                } else if options.shouldBuild {
                    try buildSystem.build(subset: .product(productName))
                }
            
                let executablePath = try swiftTool.buildParameters().buildPath.appending(component: productName)
                try run(executablePath,
                        originalWorkingDirectory: swiftTool.originalWorkingDirectory,
                        arguments: options.arguments)
            } catch let error as RunError {
                swiftTool.diagnostics.emit(error)
                throw ExitCode.failure
            }
        }
    }

    /// Returns the path to the correct executable based on options.
    private func findProductName(in graph: PackageGraph) throws -> String {
        if let executable = options.executable {
            let executableExists = graph.allProducts.contains { $0.type == .executable && $0.name == executable }
            guard executableExists else {
                throw RunError.executableNotFound(executable)
            }
            return executable
        }

        // If the executable is implicit, search through root products.
        let rootExecutables = graph.rootPackages
            .flatMap { $0.products }
            .filter { $0.type == .executable || $0.type == .nxApplication }
            .map { $0.name }

        // Error out if the package contains no executables.
        guard rootExecutables.count > 0 else {
            throw RunError.noExecutableFound
        }

        // Only implicitly deduce the executable if it is the only one.
        guard rootExecutables.count == 1 else {
            throw RunError.multipleExecutables(rootExecutables)
        }

        return rootExecutables[0]
    }

    /// Executes the executable at the specified path.
    private func run(
        _ excutablePath: AbsolutePath,
        originalWorkingDirectory: AbsolutePath,
        arguments: [String]) throws
    {
        // Make sure we are running from the original working directory.
        let cwd: AbsolutePath? = localFileSystem.currentWorkingDirectory
        if cwd == nil || originalWorkingDirectory != cwd {
            try ProcessEnv.chdir(originalWorkingDirectory)
        }

        let pathRelativeToWorkingDirectory = excutablePath.relative(to: originalWorkingDirectory)
        try exec(path: excutablePath.pathString, args: [pathRelativeToWorkingDirectory.pathString] + arguments)
    }

    /// Determines if a path points to a valid swift file.
    private func isValidSwiftFilePath(_ path: String) -> Bool {
        guard path.hasSuffix(".swift") else { return false }
        //FIXME: Return false when the path is not a valid path string.
        let absolutePath: AbsolutePath
        if path.first == "/" {
            absolutePath = AbsolutePath(path)
        } else {
            guard let cwd = localFileSystem.currentWorkingDirectory else {
                return false
            }
            absolutePath = AbsolutePath(cwd, path)
        }
        return localFileSystem.isFile(absolutePath)
    }
    
    public init() {}
}

private extension Diagnostic.Message {
    static var runFileDeprecation: Diagnostic.Message {
        .warning("'swift run file.swift' command to interpret swift files is deprecated; use 'swift file.swift' instead")
    }
}
