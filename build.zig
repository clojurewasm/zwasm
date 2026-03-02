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

    const build_zon = @import("build.zig.zon");

    const options = b.addOptions();
    options.addOption(bool, "enable_wat", enable_wat);
    options.addOption(bool, "enable_jit", enable_jit);
    options.addOption(bool, "enable_simd", enable_simd);
    options.addOption(bool, "enable_gc", enable_gc);
    options.addOption(bool, "enable_threads", enable_threads);
    options.addOption(bool, "enable_component", enable_component);
    options.addOption([]const u8, "version", build_zon.version);

    // Library module (for use as dependency and test root)
    const mod = b.addModule("zwasm", .{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
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
    });
    cli_mod.addOptions("build_options", options);
    const cli = b.addExecutable(.{
        .name = "zwasm",
        .root_module = cli_mod,
    });
    // Increase stack size for deep recursion in Debug builds (e.g. mutual recursion via call_ref)
    cli.stack_size = 64 * 1024 * 1024; // 64MB
    b.installArtifact(cli);

    // Example executables
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
        });
        ex_mod.addImport("zwasm", mod);
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = ex_mod,
        });
        b.installArtifact(ex_exe);
    }

    // E2E test runner executable
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e/e2e_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("zwasm", mod);
    const e2e = b.addExecutable(.{
        .name = "e2e_runner",
        .root_module = e2e_mod,
    });
    b.installArtifact(e2e);

    // Benchmark executable
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/fib_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zwasm", mod);
    const bench = b.addExecutable(.{
        .name = "fib_bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    // Fuzz loader executables — only built via "fuzz" step (not default install)
    // to keep default artifact count low and avoid Zig 0.15.2 build runner
    // shuffle bug on some platforms.
    const fuzz_step = b.step("fuzz", "Build fuzz loader executables");
    {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("src/fuzz_loader.zig"),
            .target = target,
            .optimize = optimize,
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
        });
        fuzz_wat_mod.addImport("zwasm", mod);
        const fuzz_wat = b.addExecutable(.{
            .name = "fuzz_wat_loader",
            .root_module = fuzz_wat_mod,
        });
        fuzz_step.dependOn(&b.addInstallArtifact(fuzz_wat, .{}).step);
    }

    // Shared library (libzwasm.dylib / libzwasm.so)
    const lib_shared_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
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
        .optimize = optimize,
    });
    lib_static_mod.addOptions("build_options", options);
    const lib_static = b.addLibrary(.{
        .linkage = .static,
        .name = "zwasm",
        .root_module = lib_static_mod,
    });
    lib_static.installHeader(b.path("include/zwasm.h"), "zwasm.h");

    // "lib" step builds both shared and static libraries
    const lib_step = b.step("lib", "Build shared and static libraries");
    lib_step.dependOn(&b.addInstallArtifact(lib_shared, .{}).step);
    lib_step.dependOn(&b.addInstallArtifact(lib_static, .{}).step);

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
