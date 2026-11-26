const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    // Early kernel code must not touch SSE or AVX: no state is enabled yet.
    const F = std.Target.x86.Feature;
    var off = std.Target.Cpu.Feature.Set.empty;
    for ([_]F{ .mmx, .sse, .sse2, .avx, .avx2 }) |f| off.addFeature(@intFromEnum(f));
    var on = std.Target.Cpu.Feature.Set.empty;
    on.addFeature(@intFromEnum(F.soft_float));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = off,
        .cpu_features_add = on,
    });
    // The kernel ships as ReleaseSafe (PRD 6b); override with -Doptimize=Debug|ReleaseFast.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default ReleaseSafe)") orelse .ReleaseSafe;

    const git_hash = b.option([]const u8, "git-hash", "Short commit hash shown in the banner") orelse gitHash(b);
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", zon.version);
    opts.addOption([]const u8, "git_hash", git_hash);
    const panic_test = b.option([]const u8, "panic-test", "Deliberate fault after boot: pf, null, ro, so, de, ud, df or assert") orelse "";
    opts.addOption([]const u8, "panic_test", panic_test);

    const kmod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small, // M0 is identity mapped at 1 MiB; higher half comes in M1
        .red_zone = false,
        .single_threaded = true,
        .unwind_tables = .none,
        .omit_frame_pointer = false, // panic backtraces walk rbp
    });
    kmod.addImport("build_options", opts.createModule());
    kmod.addAssemblyFile(b.path("src/boot.S"));
    kmod.addAssemblyFile(b.path("src/isr.S"));
    kmod.addAssemblyFile(b.path("src/ap.S"));

    const kernel = b.addExecutable(.{ .name = "nixless.elf", .root_module = kmod, .use_llvm = true });
    // The SIMD self-tests need an assembler that accepts AVX2 and AVX-512, so they
    // are their own object built for a richer CPU; the kernel proper stays SSE-free.
    var simd_on = std.Target.Cpu.Feature.Set.empty;
    for ([_]F{ .avx, .avx2, .avx512f, .avx512bw, .avx512vl }) |f| simd_on.addFeature(@intFromEnum(f));
    const simd_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = simd_on,
    });
    const simd_mod = b.createModule(.{ .target = simd_target, .optimize = optimize });
    simd_mod.addAssemblyFile(b.path("src/simd.S"));
    kmod.addObject(b.addObject(.{ .name = "simd", .root_module = simd_mod }));
    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    // Hybrid ISO (SeaBIOS and OVMF): GRUB 2 + Multiboot2.
    const iso_tree = b.addWriteFiles();
    _ = iso_tree.addCopyFile(kernel.getEmittedBin(), "boot/nixless.elf");
    // The model rides along as a Multiboot2 module. Default: the small test fixture
    // (so the boot check can run the matmul test); -Dmodel=none builds an ISO with no
    // module (the E_NO_MODEL test); -Dmodel=<path> bakes a real model in.
    const model_opt = b.option([]const u8, "model", "GGUF to put on the ISO as a module, or 'none'") orelse "tests/fixtures/tiny.gguf";
    const have_model = !std.mem.eql(u8, model_opt, "none");
    if (have_model) _ = iso_tree.addCopyFile(b.path(model_opt), "boot/model.gguf");
    const grub_tmpl = @embedFile("grub.cfg");
    const grub_cfg = std.mem.replaceOwned(u8, b.allocator, grub_tmpl, "@MODULE@", if (have_model) "module2 /boot/model.gguf model" else "") catch @panic("OOM");
    _ = iso_tree.add("boot/grub/grub.cfg", grub_cfg);
    const mkrescue = b.addSystemCommand(&.{"grub-mkrescue"});
    mkrescue.addArg("-o");
    const iso = mkrescue.addOutputFileArg("nixless.iso");
    mkrescue.addDirectoryArg(iso_tree.getDirectory());
    const iso_step = b.step("iso", "Build zig-out/nixless.iso (needs grub-mkrescue, xorriso, mtools)");
    iso_step.dependOn(&b.addInstallFile(iso, "nixless.iso").step);

    // Host-side parser tests: zig build test
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/gguf_test.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    test_mod.addAnonymousImport("tiny.gguf", .{ .root_source_file = b.path("tests/fixtures/tiny.gguf") });
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run the host-side GGUF parser tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn gitHash(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ "git", "describe", "--always", "--dirty", "--abbrev=7" }, &code, .ignore) catch return "nogit";
    return std.mem.trim(u8, out, " \n\r");
}
