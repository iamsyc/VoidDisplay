import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { selectUITests, suiteMappings } from "../lib/ui_test_selection.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const readSource = relative => readFileSync(path.join(root, relative), "utf8");

test("report and selector CLIs execute through symlinked tool roots", () => {
    const temporaryRoot = process.env.AI_TMP_DIR ?? path.join(root, ".ai-tmp");
    mkdirSync(temporaryRoot, { recursive: true });
    const fixture = mkdtempSync(path.join(temporaryRoot, "test-quality-cli."));
    try {
        const alias = path.join(fixture, "repository");
        symlinkSync(root, alias, "dir");
        const log = path.join(fixture, "run.log");
        writeFileSync(log, "    t = 0.01s Launch com.developerchen.voiddisplay\n");
        for (const options of [[], ["--preserve-symlinks-main"]]) {
            const selection = execFileSync(process.execPath, [...options, path.join(alias, "scripts/lib/ui_test_selection.mjs"), alias, '["Package.swift"]'], { encoding: "utf8" });
            assert.deepEqual(JSON.parse(selection), ["VoidDisplayUITests"]);
            const output = path.join(fixture, `report-${options.length}`);
            execFileSync(process.execPath, [...options, path.join(alias, "scripts/lib/ui_test_report.mjs"), "--log-only", log, "platform=macOS", output]);
            assert.equal(JSON.parse(readFileSync(`${output}.json`, "utf8")).recorded_launches, 1);
            assert.match(readFileSync(`${output}.md`, "utf8"), /1 app launches/);
        }
    } finally {
        rmSync(fixture, { recursive: true, force: true });
    }
});

test("changed UI test classes include every method without parsing commented methods", () => {
    const selected = selectUITests(["UITests/Example.swift"], () => "final class ExampleTests: XCTestCase { func testNewBehavior() {} }");
    assert.ok(selected.includes("VoidDisplayUITests/ExampleTests"));
    const commented = selectUITests(["UITests/Example.swift"], () => "final class ExampleTests: XCTestCase {\n // func testRemovedFlow() was replaced\n func testCurrentFlow() {}\n}");
    assert.deepEqual(commented, selected);
});
test("menu changes select menu acceptance and common navigation", () => {
    const selected = selectUITests(["Sources/VoidDisplayApp/Navigation/MenuBarQuickActionsView.swift"], readSource);
    assert.ok(selected.includes("VoidDisplayUITests/MenuBarQuickActionsSmokeTests"));
    assert.ok(selected.some(selector => selector.includes("testHomeCoreJourney")));
});
test("shared infrastructure and deleted tests require the complete UI target", () => {
    for (const file of ["Sources/VoidDisplayRuntime/Runtime.swift", "Package.swift", "scripts/ci/ui_smoke.sh", "UITests/deleted.swift"]) {
        assert.deepEqual(selectUITests([file], readSource), ["VoidDisplayUITests"]);
    }
});
test("suite selection removes redundant method selectors", () => {
    const selected = selectUITests(["Sources/VoidDisplayVirtualDisplay/Display.swift"], readSource);
    assert.ok(selected.includes("VoidDisplayUITests/HomeSmokeTests"));
    assert.ok(!selected.some(selector => selector.includes("HomeSmokeTests/test")));
});
test("every mapped suite exists in the current UI target", () => {
    const directory = path.join(root, "UITests/VoidDisplayUITests");
    const sources = readdirSync(directory, { recursive: true }).filter(file => file.endsWith(".swift"))
        .map(file => readFileSync(path.join(directory, file), "utf8")).join("\n");
    for (const suite of new Set(suiteMappings.flatMap(([, suites]) => suites))) {
        assert.match(sources, new RegExp(`final class ${suite}: XCTestCase`));
    }
});

import { uiTestReport, uiTestMarkdown, combineUITestReports } from "../lib/ui_test_report.mjs";
import { coverageReport, coverageMarkdown } from "../lib/coverage_report.mjs";

test("UI report uses xcresult durations, records failed phase and reruns only the failed selector", () => {
    const tests = { testNodes: [{ children: [{ nodeType: "Test Case", nodeIdentifierURL: "test://com.apple.xcode/VoidDisplay/VoidDisplayUITests/ExampleTests/testAction", durationInSeconds: 1.25, result: "Failed" }] }] };
    const log = "Test Case '-[VoidDisplayUITests.ExampleTests testAction]' started.\n    t = 0.01s Launch com.developerchen.voiddisplay\n[UI_STEP] Open diagnostics\nerror: Assertion Failure\nTest Case '-[VoidDisplayUITests.ExampleTests testAction]' failed (1.250 seconds).";
    const report = uiTestReport(tests, log, "platform=macOS,arch=arm64");
    assert.equal(report.executed_launches, 1);
    assert.equal(report.test_duration_seconds, 1.25);
    assert.equal(report.cases[0].failure_step, "Open diagnostics");
    assert.match(report.cases[0].rerun_command, /VoidDisplayUITests\/ExampleTests\/testAction/);
    assert.match(uiTestMarkdown(report), /Open diagnostics/);
    const reused = uiTestReport(tests, log, "platform=macOS,arch=arm64", true);
    assert.equal(reused.executed_launches, 0);
    assert.equal(reused.recorded_launches, 1);
});

function llvmFixture(covered = 2) {
    const summary = Object.fromEntries(["lines", "regions", "functions"].map(metric => [metric, { count: 4, covered }]));
    return { type: "llvm.coverage.json.export", data: [{ files: [
        { filename: "/repo/Sources/Module/Example.swift", summary, segments: [[10, 1, 0, true, true, false], [11, 1, 2, true, true, false], [12, 1, 0, true, false, false], [13, 1, 0, true, true, true]] },
        { filename: "/repo/Tests/Test.swift", summary, segments: [] }
    ] }] };
}

test("coverage reports source modules and region starts, excluding tests and gap segments", () => {
    const report = coverageReport(llvmFixture(), "/repo");
    assert.equal(report.modules.Module.lines.percent, 50);
    assert.equal(report.modules.Module.lines.delta_percentage_points, null);
    assert.deepEqual(report.files[0].uncovered_region_starts, [10]);
    assert.equal(report.files.length, 1);
    assert.match(coverageMarkdown(report), /first baseline/);
});
test("coverage baseline reports percentage point changes and rejects missing or invalid evidence", () => {
    const baseline = { ...coverageReport(llvmFixture(), "/repo"), revision: "old" };
    const report = coverageReport(llvmFixture(3), "/repo", baseline);
    assert.equal(report.modules.Module.lines.delta_percentage_points, 25);
    assert.equal(report.baseline_revision, "old");
    assert.throws(() => coverageReport({}, "/repo"), /Invalid LLVM/);
    assert.throws(() => coverageReport(llvmFixture(), "/elsewhere"), /no project source/);
    assert.throws(() => coverageReport(llvmFixture(5), "/repo"), /Invalid lines/);
});


test("a changed file with multiple test classes runs the full target", () => {
    const source = "final class FirstTests: XCTestCase { func testOpen() {} } final class SecondTests: XCTestCase { func testOpen() {} }";
    assert.deepEqual(selectUITests(["UITests/Mixed.swift"], () => source), ["VoidDisplayUITests"]);
});
test("UI reports unknown counts as unavailable and do not blame a completed phase", () => {
    const tests = { testNodes: [{ nodeType: "Test Case", nodeIdentifierURL: "test://com.apple.xcode/VoidDisplay/VoidDisplayUITests/HomeSmokeTests/testHomeCoreJourney", durationInSeconds: 1, result: "Failed" }] };
    assert.equal(uiTestReport(tests, "", "macOS").executed_launches, null);
    const log = "Test Case '-[VoidDisplayUITests.HomeSmokeTests testHomeCoreJourney]' started.\n[UI_STEP] Popover\n[UI_STEP_END] Popover\nerror: width assertion";
    assert.equal(uiTestReport(tests, log, "macOS").cases[0].failure_step, null);
});

test("UI retries retain every attempt cost and failure, while reuse executes nothing", () => {
    const failed = { recorded_launches: 1, test_duration_seconds: 2, cases: [{ selector: "Target/Test/testOne", result: "Failed", failure_step: "Open" }] };
    const passed = { recorded_launches: 1, test_duration_seconds: 3, cases: [{ selector: "Target/Test/testOne", result: "Passed" }] };
    const report = combineUITestReports([failed, passed]);
    assert.equal(report.executed_launches, 2);
    assert.equal(report.test_duration_seconds, 5);
    assert.equal(report.unique_tests, 1);
    assert.deepEqual(report.cases.map(item => item.attempt), [1, 2]);
    assert.equal(report.cases[0].failure_step, "Open");
    assert.equal(combineUITestReports([report], true).executed_launches, 0);
    assert.equal(combineUITestReports([report], true).attempts, 2);
});
