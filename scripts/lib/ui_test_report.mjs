import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const quote = value => `'${value.replaceAll("'", "'\"'\"'")}'`;
const walk = node => [node, ...(node.children ?? []).flatMap(walk)];
const sumKnown = values => values.length && values.every(value => Number.isFinite(value)) ? values.reduce((a, b) => a + b, 0) : null;

export function uiTestReport(tests, log, destination, reused = false) {
    const runs = new Map();
    let current;
    for (const line of log.split("\n")) {
        const start = line.match(/Test Case '-\[(\w+)\.(\w+) (\w+)\]' started/);
        if (start) {
            const selector = start.slice(1).join("/");
            current = runs.get(selector) ?? { launches: 0, steps: [], activeSteps: [], failure_step: null };
            runs.set(selector, current);
        }
        if (current && /\bLaunch com\.developerchen\.voiddisplay\s*$/.test(line)) current.launches++;
        const step = line.match(/\[UI_STEP\] (.+)/)?.[1];
        if (current && step) { current.steps.push(step); current.activeSteps.push(step); }
        if (current && line.includes("[UI_STEP_END]")) current.activeSteps.pop();
        if (current && /error:|failed -|Assertion Failure/.test(line)) current.failure_step ??= current.activeSteps.at(-1) ?? null;
        if (/Test Case '.+' (passed|failed|skipped) \(/.test(line)) current = undefined;
    }
    const cases = (tests.testNodes ?? []).flatMap(walk).filter(node => node.nodeType === "Test Case").map(node => {
        const url = node.nodeIdentifierURL ?? "";
        const selector = decodeURIComponent(url.slice(url.indexOf("/VoidDisplayUITests") + 1));
        const run = runs.get(selector);
        return {
            selector,
            result: node.result,
            duration_seconds: node.durationInSeconds ?? null,
            launches: run?.launches ?? null,
            steps: run?.steps ?? [],
            failure_step: run?.failure_step ?? null,
            rerun_command: node.result === "Passed" ? null : `scripts/ci/ui_smoke.sh --only-testing ${quote(selector)} --destination ${quote(destination)} --rerun`
        };
    }).sort((a, b) => (b.duration_seconds ?? 0) - (a.duration_seconds ?? 0));
    const recordedLaunches = log ? [...log.matchAll(/\bLaunch com\.developerchen\.voiddisplay\s*$/gm)].length : null;
    return {
        schema_version: 1,
        evidence_reused: reused,
        total_tests: cases.length,
        recorded_launches: recordedLaunches,
        executed_launches: reused ? 0 : recordedLaunches,
        test_duration_seconds: sumKnown(cases.map(item => item.duration_seconds)),
        cases
    };
}

export function combineUITestReports(reports, reused = false) {
    const cases = reports.flatMap((report, index) => report.cases.map(item => ({ ...item, attempt: item.attempt ?? index + 1 })));
    const recordedLaunches = sumKnown(reports.map(report => report.recorded_launches));
    return {
        schema_version: 1, evidence_reused: reused,
        total_tests: cases.length, unique_tests: new Set(cases.map(item => item.selector)).size,
        attempts: reports.reduce((count, report) => count + (report.attempts ?? 1), 0),
        recorded_launches: recordedLaunches, executed_launches: reused ? 0 : recordedLaunches,
        test_duration_seconds: sumKnown(reports.map(report => report.test_duration_seconds)), cases
    };
}

export function uiTestMarkdown(report) {
    const rows = report.cases.map(item => `| ${item.attempt ?? 1} | ${item.selector} | ${item.duration_seconds?.toFixed(3) ?? "unavailable"} | ${item.launches ?? "unavailable"} | ${item.result} |`);
    const failures = report.cases.filter(item => item.rerun_command).map(item =>
        `\n${item.selector}: ${item.failure_step ?? "See the result bundle for the failed activity."}\n\n\`\`\`sh\n${item.rerun_command}\n\`\`\``);
    return `# UI test report\n\n${report.total_tests} case executions; ${report.executed_launches ?? "unavailable"} app launches in this invocation; ${report.test_duration_seconds?.toFixed(3) ?? "unavailable"} s recorded test time. Evidence reused: ${report.evidence_reused}.\n\n| Attempt | Test | Seconds | Recorded launches | Result |\n| ---: | --- | ---: | ---: | --- |\n${rows.join("\n")}\n${failures.join("\n")}\n`;
}

if (existsSync(process.argv[1] ?? "") && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
    let report, output;
    if (process.argv[2] === "--combine") {
        const [, , , outputPath, reused, ...inputs] = process.argv;
        output = outputPath;
        report = combineUITestReports(inputs.map(input => JSON.parse(readFileSync(input, "utf8"))), reused === "true");
    } else if (process.argv[2] === "--log-only") {
        const [logPath, destination, outputPath] = process.argv.slice(3);
        output = outputPath;
        report = uiTestReport({}, existsSync(logPath) ? readFileSync(logPath, "utf8") : "", destination);
        report.result_data_available = false;
    } else {
        const [bundle, logPath, destination, outputPath, reused] = process.argv.slice(2);
        output = outputPath;
        const tests = JSON.parse(execFileSync("xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", bundle], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }));
        report = uiTestReport(tests, existsSync(logPath) ? readFileSync(logPath, "utf8") : "", destination, reused === "true");
    }
    writeFileSync(`${output}.json`, JSON.stringify(report, null, 2) + "\n");
    writeFileSync(`${output}.md`, uiTestMarkdown(report));
}
