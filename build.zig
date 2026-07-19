const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zregex_dep = b.dependency("zregex", .{ .target = target, .optimize = optimize });
    const zregex_module = zregex_dep.module("zregex");

    const zlexer_module = b.addModule("zlexer", .{
        .root_source_file = b.path("src/zlexer.zig"),
    });
    zlexer_module.addImport("zregex", zregex_module);

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/punctuator_test.zig",
        "tests/numeric_test.zig",
        "tests/string_test.zig",
        "tests/template_test.zig",
        "tests/regex_test.zig",
        "tests/identifier_test.zig",
        "tests/asi_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });

        unit_tests.root_module.addImport("zlexer", zlexer_module);
        unit_tests.root_module.addImport("zregex", zregex_module);

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Also run the tests inlined across src/*.zig.
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zlexer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addImport("zregex", zregex_module);
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    b.default_step = test_step;
}
