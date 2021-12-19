/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import PackageModel
import Workspace
import SPMBuildCore
import Basics

public extension Destination {
    static func forKlepto(
        diagnostics: DiagnosticsEngine,
        dkp devkitproPath: String,
        toolchain kleptoToolchainPath: String,
        kleptoSpecsPath: String,
        kleptoIsystem: [String],
        kleptoIcuPaths: [String],
        kleptoLlvmBinPath: String
    ) -> Destination? {
        let ccFlags = [
            "-Wno-gnu-include-next",
            "-D__SWITCH__",
            "-D__DEVKITA64__",
            "-D__unix__",
            "-D__linux__",
            "-fPIE",
            "-nostdinc",
            "-nostdinc++",
            "-D_POSIX_C_SOURCE=200809",
            "-D_GNU_SOURCE",
            // libnx already included in isystem
            "-I\(devkitproPath)/portlibs/switch/include/",
            "-fno-blocks",
            "-mno-tls-direct-seg-refs",
            "-Qunused-arguments",
            "-Xclang", "-target-feature",
            "-Xclang", "+read-tp-soft",
            "-ftls-model=local-exec",
        ] + kleptoIsystem.map {"-isystem\($0)"}

        var swiftcFlags = [
            "-static-stdlib",
            "-D", "__SWITCH__",
        ]

        for ccFlag in ccFlags {
            swiftcFlags += ["-Xcc", ccFlag]
        }

        let triple = try! Triple("aarch64-none-unknown-elf")

        var destination = Destination(
            target: triple,
            sdk: AbsolutePath(kleptoToolchainPath),
            binDir: AbsolutePath(kleptoToolchainPath).appending(components: "usr", "bin"),
            extraCCFlags: ccFlags,
            extraSwiftCFlags: swiftcFlags,
            extraCPPFlags: ccFlags
        )

        destination.devkitproPath = devkitproPath
        destination.kleptoSpecsPath = kleptoSpecsPath
        destination.kleptoIcuPaths = kleptoIcuPaths
        destination.kleptoLlvmBinPath = kleptoLlvmBinPath
        destination.isKlepto = true

        return destination
    }
}

public extension ManifestLoader {
    convenience init(
        manifestResources: ManifestResourceProvider,
        serializedDiagnostics: Bool = false,
        isManifestSandboxEnabled: Bool = true,
        cacheDir: AbsolutePath? = nil,
        delegate: ManifestLoaderDelegate? = nil,
        extraManifestFlags: [String] = [],
        klepto: Bool
    ) {
        self.init(
            manifestResources: manifestResources,
            serializedDiagnostics: serializedDiagnostics,
            isManifestSandboxEnabled: isManifestSandboxEnabled,
            cacheDir: cacheDir,
            delegate: delegate,
            extraManifestFlags: extraManifestFlags + (klepto ? ["-D", "__SWITCH__"] : [])
        )
    }
}

public func buildKleptoLinkArguments(
    productType: ProductType,
    devkitproPath: String,
    binaryPath: String,
    kleptoSpecsPath: String,
    kleptoIcuPaths: [String],
    kleptoLlvmBinPath: String
) throws -> [String] {
    if productType == .nxApplication {
        var args: [String] = []

        let additional_args = [
            "-Map", "\(binaryPath).map",
        ]

        for arg in additional_args {
            args += ["-Xlinker", arg]
        }

        args += ["-static-executable"]

        args += ["-use-ld=\(devkitproPath)/devkitA64/bin"]
        args += ["-tools-directory", kleptoLlvmBinPath]
        args += ["-specs=\(kleptoSpecsPath)"]

        for path in kleptoIcuPaths {
            args += ["-Xlinker", "-L\(path)"]
        }

        args += ["-Xlinker", "-L\(devkitproPath)/libnx/lib"]
        args += ["-Xlinker", "-L\(devkitproPath)/portlibs/switch/lib"]
        args += ["-Xlinker", "-lnx"]

        return args
    }
    else {
        throw InternalError("product type not supported")
    }
}

public func buildKleptoElf2NroArguments(
    devkitproPath: String,
    input: AbsolutePath,
    output: AbsolutePath
) -> [String] {
        return [
            "\(devkitproPath)/tools/bin/elf2nro",
            input.pathString,
            output.pathString
        ]
    }
