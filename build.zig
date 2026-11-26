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

    const kmod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small, // M0 is identity mapped at 1 MiB; higher half comes in M1
        .red_zone = false,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    kmod.addImport("build_options", opts.createModule());
    kmod.addAssemblyFile(b.path("src/boot.S"));

    const kernel = b.addExecutable(.{ .name = "nixless.elf", .root_module = kmod, .use_llvm = true });
    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    // Hybrid ISO (SeaBIOS and OVMF): GRUB 2 + Multiboot2.
    const iso_tree = b.addWriteFiles();
    _ = iso_tree.addCopyFile(kernel.getEmittedBin(), "boot/nixless.elf");
    _ = iso_tree.addCopyFile(b.path("grub.cfg"), "boot/grub/grub.cfg");
    const mkrescue = b.addSystemCommand(&.{"grub-mkrescue"});
    mkrescue.addArg("-o");
    const iso = mkrescue.addOutputFileArg("nixless.iso");
    mkrescue.addDirectoryArg(iso_tree.getDirectory());
    const iso_step = b.step("iso", "Build zig-out/nixless.iso (needs grub-mkrescue, xorriso, mtools)");
    iso_step.dependOn(&b.addInstallFile(iso, "nixless.iso").step);
}

fn gitHash(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ "git", "describe", "--always", "--dirty", "--abbrev=7" }, &code, .ignore) catch return "nogit";
    return std.mem.trim(u8, out, " \n\r");
}
