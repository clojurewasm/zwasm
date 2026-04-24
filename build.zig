const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options — feature flags for conditional compilation
    const enable_wat = b.option(bool, "wat", "Enable WAT text format parser (default: true)") orelse true;
    const enable_jit = b.option(bool, "jit", "Enable JIT compiler (default: true)") orelse true;
    const enable_simd = b.option(bool, "simd", "Enable SIMD opcodes (default: true)") orelse true;
    const enable_gc = b.option(bool, "gc", "Enable GC proposal (default: true)") orelse true;
    const enable_threads = b.option(bool, "threads", "Enable threads/atomics (default: true)") orelse true;
    const enable_component = b.option(bool, "component", "Enable component model (default: true)") orelse true;

    // Static library options — needed when linking libzwasm.a from non-Zig toolchains
    const enable_pic = b.option(bool, "pic", "Enable Position Independent Code for static library") orelse false;
    const bundle_compiler_rt = b.option(bool, "compiler-rt", "Bundle compiler_rt into static library") orelse false;

    const build_zon = @import("build.zig.zon");

    const options = b.addOptions();
    options.addOption(bool, "enable_wat", enable_wat);
    options.addOption(bool, "enable_jit", enable_jit);
    options.addOption(bool, "enable_simd", enable_simd);
    options.addOption(bool, "enable_gc", enable_gc);
    options.addOption(bool, "enable_threads", enable_threads);
    options.addOption(bool, "enable_component", enable_component);
    options.addOption([]const u8, "version", build_zon.version);

    // Library module (for use as dependency and test root).
    // link_libc = false post-W46 migration. WASI fd I/O and path-based ops
    // now go through `platform.pfd*` helpers (Linux syscalls / Mac libSystem
    // auto-link / Win32 kernel32). Env vars come from `std.process.Environ.Map`
    // captured in `cli.main` (W46 Phase 1e). The `std.c.*` references that
    // survive are all inside `else` branches of `switch (comptime builtin.os.tag)`
    // blocks, so they are comptime-pruned on Linux/Windows and still resolve
    // to libSystem on Mac.
    const mod = b.addModule("zwasm", .{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    mod.addOptions("build_options", options);

    // Tests
    const tests = b.addTest(.{
        .root_module = mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // CLI executable (zwasm run/inspect/validate)
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    cli_mod.addOptions("build_options", options);
    const cli = b.addExecutable(.{
        .name = "zwasm",
        .root_module = cli_mod,
    });
    // Increase stack size for deep recursion in Debug builds (e.g. mutual recursion via call_ref)
    cli.stack_size = 64 * 1024 * 1024; // 64MB
    b.installArtifact(cli);

    // Example executables — only built via "examples" step (not default install)
    // to keep default artifact count low and avoid Zig 0.15.2 build runner
    // shuffle bug on some platforms (crashes with >=8 default install artifacts).
    const examples_step = b.step("examples", "Build example executables");
    const examples = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "example_basic", .src = "examples/zig/basic.zig" },
        .{ .name = "example_memory", .src = "examples/zig/memory.zig" },
        .{ .name = "example_inspect", .src = "examples/zig/inspect.zig" },
        .{ .name = "example_host_functions", .src = "examples/zig/host_functions.zig" },
        .{ .name = "example_wasi", .src = "examples/zig/wasi.zig" },
    };
    for (examples) |ex| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(ex.src),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        ex_mod.addImport("zwasm", mod);
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = ex_mod,
        });
        examples_step.dependOn(&b.addInstallArtifact(ex_exe, .{}).step);
    }

    // E2E test runner executable — only built via "e2e" step
    const e2e_step = b.step("e2e", "Build E2E test runner");
    {
        const e2e_mod = b.createModule(.{
            .root_source_file = b.path("test/e2e/e2e_runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        e2e_mod.addImport("zwasm", mod);
        const e2e = b.addExecutable(.{
            .name = "e2e_runner",
            .root_module = e2e_mod,
        });
        e2e_step.dependOn(&b.addInstallArtifact(e2e, .{}).step);
    }

    // Benchmark executable — only built via "bench" step
    const bench_step = b.step("bench", "Build benchmark executable");
    {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path("bench/fib_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        bench_mod.addImport("zwasm", mod);
        const bench = b.addExecutable(.{
            .name = "fib_bench",
            .root_module = bench_mod,
        });
        bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);
    }

    // Fuzz loader executables — only built via "fuzz" step (not default install)
    // to keep default artifact count low and avoid Zig 0.15.2 build runner
    // shuffle bug on some platforms.
    const fuzz_step = b.step("fuzz", "Build fuzz loader executables");
    {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("src/fuzz_loader.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        fuzz_mod.addImport("zwasm", mod);
        const fuzz = b.addExecutable(.{
            .name = "fuzz_loader",
            .root_module = fuzz_mod,
        });
        fuzz_step.dependOn(&b.addInstallArtifact(fuzz, .{}).step);

        const fuzz_wat_mod = b.createModule(.{
            .root_source_file = b.path("src/fuzz_wat_loader.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        fuzz_wat_mod.addImport("zwasm", mod);
        const fuzz_wat = b.addExecutable(.{
            .name = "fuzz_wat_loader",
            .root_module = fuzz_wat_mod,
        });
        fuzz_step.dependOn(&b.addInstallArtifact(fuzz_wat, .{}).step);
    }

    // Shared library (libzwasm.dylib / libzwasm.so)
    // Default to ReleaseSafe: Zig 0.15's Debug-mode shared libraries
    // crash on Linux x86_64 due to GPA/PIC codegen issues (see #11).
    // Users embedding zwasm want optimized code anyway.
    const lib_optimize = b.option(bool, "lib-debug", "Build libraries in Debug mode (default: false)") orelse false;
    const lib_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = if (lib_optimize) optimize else if (optimize == .Debug) .ReleaseSafe else optimize,
        .link_libc = false,
    });
    lib_shared_mod.addOptions("build_options", options);
    const lib_shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zwasm",
        .root_module = lib_shared_mod,
    });
    lib_shared.installHeader(b.path("include/zwasm.h"), "zwasm.h");

    // Static library (libzwasm.a)
    const lib_static_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = if (lib_optimize) optimize else if (optimize == .Debug) .ReleaseSafe else optimize,
        .link_libc = false,
        .pic = if (enable_pic) true else null,
    });
    lib_static_mod.addOptions("build_options", options);
    const lib_static = b.addLibrary(.{
        .linkage = .static,
        .name = "zwasm",
        .root_module = lib_static_mod,
    });
    lib_static.bundle_compiler_rt = bundle_compiler_rt;
    lib_static.installHeader(b.path("include/zwasm.h"), "zwasm.h");

    // Separate steps to avoid Zig 0.15.2 build graph shuffle bug
    // when two same-named artifacts are in the same step.
    const shared_lib_step = b.step("shared-lib", "Build shared library (libzwasm.so/.dylib)");
    shared_lib_step.dependOn(&b.addInstallArtifact(lib_shared, .{}).step);

    const static_lib_step = b.step("static-lib", "Build static library (libzwasm.a)");
    static_lib_step.dependOn(&b.addInstallArtifact(lib_static, .{}).step);

    // "lib" step builds both shared and static libraries
    const lib_step = b.step("lib", "Build shared and static libraries");
    lib_step.dependOn(shared_lib_step);
    lib_step.dependOn(static_lib_step);

    // C API test executables (link against static library)
    const c_tests = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "test_c_api_basic", .src = "test/c_api/test_basic.c" },
        .{ .name = "example_c_hello", .src = "examples/c/hello.c" },
    };
    const c_test_step = b.step("c-test", "Build and run C API tests");
    for (c_tests) |ct| {
        const ct_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        ct_mod.addCSourceFile(.{ .file = b.path(ct.src) });
        ct_mod.addIncludePath(b.path("include"));
        ct_mod.linkLibrary(lib_static);
        const ct_exe = b.addExecutable(.{
            .name = ct.name,
            .root_module = ct_mod,
        });
        // Install only via c-test step (not default install) to keep artifact count
        // below Zig 0.15.2 build runner shuffle bug threshold on some platforms.
        c_test_step.dependOn(&b.addInstallArtifact(ct_exe, .{}).step);
        const run_ct = b.addRunArtifact(ct_exe);
        c_test_step.dependOn(&run_ct.step);
    }
}
