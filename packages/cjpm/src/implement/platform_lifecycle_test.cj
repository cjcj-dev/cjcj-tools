// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// This source file is part of the Cangjie project, licensed under Apache-2.0
// with Runtime Library Exception.
//
// See https://cangjie-lang.cn/pages/LICENSE for license information.

package cjpm.implement

import std.collection.*
import std.env.getTempDirectory
import std.fs.*
import std.sync.Semaphore
import std.unittest.*
import std.unittest.testmacro.*
import cjpm.config.*

private func testBinDeps(directory: Path): HashMap<String, BinDeps> {
    Directory.create(directory)
    // These files model the on-disk inputs for argv construction; the CLI suite uses real archives.
    File.writeTo(directory.join("libchoice.a"), Array<Byte>())
    File.writeTo(directory.join(makeLtoName("choice")), Array<Byte>())
    let deps = BinDeps()
    let info = RequiresPackagesInfo(false, directory.toString(), directory.toString())
    info.libName = "choice"
    deps.packageRequires.add("choice", info)
    deps.packageRequiresSort.add("choice")
    HashMap<String, BinDeps>([("demo", deps)])
}

private func withBinDeps(run: (Path, BuildConfig) -> Unit): Unit {
    let scratch = Directory.createTemp(getTempDirectory())
    try {
        let cfg = BuildConfig()
        cfg.isCrossCompile = true
        cfg.binDepMap = testBinDeps(scratch.join("host"))
        cfg.crossBinDepMap = testBinDeps(scratch.join("target"))
        cfg.requiresMap.add("demo", HashSet<String>(["choice"]))
        run(scratch, cfg)
    } finally {
        remove(scratch, recursive: true)
    }
}

private func sampleTask(triple: String, cross!: Bool = true,
    mode!: CompileTaskCombineFlags = CompileTaskCombineFlags()): CompileTask {
    CompileTask(id: Compile("demo", triple, false, false, Dynamic, ""), fullName: "demo",
        rootPkgName: "demo", target: triple, isCrossCompile: cross, combineFlags: mode)
}

@Test
func ordinaryBinaryLinkHasNoPlatformFallback(): Unit {
    withBinDeps { scratch, cfg =>
        let target = sampleTask("aarch64-unknown-linux-gnu")
        @Assert(getBuildArgs(target, cfg).toArray(), ["-L", scratch.join("target").toString(), "-lchoice"])
        cfg.crossBinDepMap.clear()
        @Assert(getBuildArgs(target, cfg).isEmpty())
        cfg.crossBinDepMap = testBinDeps(scratch.join("targetonly"))
        cfg.binDepMap.clear()
        let host = sampleTask("x86_64-unknown-linux-gnu", cross: false)
        @Assert(getBuildArgs(host, cfg).isEmpty())
    }
}

@Test
func hostTaskKeepsHostBinaryAndNativeCWhenBuildIsCross(): Unit {
    withBinDeps { scratch, cfg =>
        cfg.globalConfig.cLibLinkMap.add("demo", ArrayList<String>(["-lhost_c"]))
        cfg.globalConfig.crossCLibLinkMap.add("demo", ArrayList<String>(["-ltarget_c"]))
        let host = sampleTask("x86_64-unknown-linux-gnu", cross: false)
        @Assert(getBuildArgs(host, cfg).toArray(),
            ["-L", scratch.join("host").toString(), "-lchoice", "-lhost_c"])
    }
}

@Test
func forcedBinaryLinkUsesTheTaskPlatform(): Unit {
    withBinDeps { scratch, cfg =>
        let before = crossCompileTarget
        try {
            for (target in ["aarch64-unknown-linux-gnu", "x86_64-w64-mingw32", "aarch64-apple-darwin"]) {
                crossCompileTarget = target
                let task = sampleTask(target)
                let deps = HashSet<String>(["choice"])
                let targetDir = scratch.join("target")
                let expected = if (target.contains("darwin")) {
                    [targetDir.join("libchoice.a").toString()]
                } else {
                    ["-L", targetDir.toString(), "-lchoice"]
                }
                @Assert(getForcedBinDep(task, cfg, deps).toArray(), expected)
            }
        } finally {
            crossCompileTarget = before
        }
    }
}

@Test
func projectLtoUsesOnlyTargetBitcode(): Unit {
    withBinDeps { scratch, cfg =>
        let task = sampleTask("aarch64-unknown-linux-gnu",
            mode: CompileTaskCombineFlags(isLto: true, isCombined: true, isProjectCombined: true))
        @Assert(getLtoCombineBuildArgs(task, cfg).toArray(),
            [scratch.join("target").join(makeLtoName("choice")).toString()])
    }
}

@Test
func testBinaryLinksOnlyTargetAndSkipsMacroArchives(): Unit {
    withBinDeps { scratch, cfg =>
        let deps = cfg.crossBinDepMap["demo"]
        let macroInfo = RequiresPackagesInfo(true, "", scratch.join("host").toString())
        macroInfo.libName = "choice"
        deps.packageRequires.add("macroarchive", macroInfo)
        deps.packageRequiresSort.add("macroarchive")
        let res = ModuleResolve(binDeps: cfg.binDepMap, crossBinDeps: cfg.crossBinDepMap)
        let tc = TestConfig()
        tc.isCrossCompile = true
        @Assert(getLinkList(res, "demo", HashSet<String>(["choice", "macroarchive"]), tc).toArray(),
            ["-L", scratch.join("target").toString(), "-lchoice"])
    }
}

private func assertRegistryDrain(throws: Bool): Unit {
    let permit = Semaphore(2)
    let drainingStarted = Semaphore(1)
    let startLast = Semaphore(1)
    permit.acquire(amount: 2)
    drainingStarted.acquire()
    startLast.acquire()
    let failed = spawn { =>
        try {
            if (throws) {
                throw Exception("registry fixture failure")
            }
            return false
        } finally {
            permit.release()
        }
    }
    let normal = spawn { =>
        try {
            startLast.acquire()
            return true
        } finally {
            permit.release()
        }
    }
    let draining = spawn { =>
        drainingStarted.release()
        waitForRegistryDownloads(ArrayList<Future<Bool>>([failed, normal]))
    }
    drainingStarted.acquire()
    let waited = try {
        draining.get(500 * Duration.millisecond)
        false
    } catch (_: TimeoutException) {
        true
    } finally {
        startLast.release()
    }
    let result = draining.get()
    let completed = normal.get()
    let returnedPermits = permit.tryAcquire(amount: 2)
    @Assert(waited, true)
    @Assert(result, false)
    @Assert(completed, true)
    @Assert(returnedPermits, true)
}

@Test
func registryDownloadsDrainAfterFailure(): Unit {
    assertRegistryDrain(false)
    assertRegistryDrain(true)
}

@Test
func registryDownloadsReportSuccessAfterJoin(): Unit {
    let one = spawn { => true }
    let two = spawn { => true }
    @Assert(waitForRegistryDownloads(ArrayList<Future<Bool>>([one, two])), true)
}
