#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { matchesGlob } from "node:path";

function uploadPaths(workflowName, stepName, jobName) {
    const workflow = readFileSync(new URL(`../../.github/workflows/${workflowName}`, import.meta.url), "utf8");
    const job = jobName ? workflow.split(`  ${jobName}:\n`)[1]?.split(/^  \w+:/m)[0] : workflow;
    assert.ok(job, `Missing job: ${jobName}`);
    const step = job.split(`      - name: ${stepName}\n`)[1]?.split(/^      - name:|^  \w+:/m)[0];
    assert.ok(step, `Missing upload step: ${stepName}`);
    const value = step.match(/^          path: (.+)$/m)?.[1];
    assert.ok(value, `Missing artifact paths: ${stepName}`);
    return value === "|"
        ? step.match(/            .+\n/g).map(line => line.trim())
        : [value];
}

function selected(paths, candidate) {
    const match = pattern => matchesGlob(candidate, pattern) || candidate.startsWith(`${pattern}/`);
    return paths.some(pattern => !pattern.startsWith("!") && match(pattern))
        && !paths.some(pattern => pattern.startsWith("!") && match(pattern.slice(1)));
}

const fixtures = [
    ["ci.yml", "Upload Xcode build artifacts", ".ai-tmp/xcode-build", ["xcode-summary.json", "xcode-build-Debug.log"], ["DerivedData/Build/Products/Debug/VoidDisplay.app/Contents/MacOS/VoidDisplay", "DerivedData/SourcePackages/checkouts/package/file.swift"]],
    ["ci.yml", "Upload release smoke artifacts", ".ai-tmp/release-check-arm64", ["release-smoke-summary.json", "xcode-release-build.log"], ["DerivedData/Build/Products/Release/VoidDisplay.app/Contents/MacOS/VoidDisplay"]],
    ["ci.yml", "Upload release smoke artifacts", ".ai-tmp/release-check-intel64", ["release-smoke-summary.json", "xcode-release-build.log"], ["DerivedData/Build/Products/Release/VoidDisplay.app/Contents/MacOS/VoidDisplay"], "release_build_check_intel64"],
    ["_reusable-ui-smoke-tests.yml", "Upload UI smoke artifacts", ".ai-tmp/ci-ui-smoke", ["ui-smoke-summary.json", "ui-test-report.md", "runs/selector/invocation.1/attempt-1/XcodeTests.xcresult/Data/data.0"], ["evidence/builds/key/DerivedData/Build/Products/Debug/VoidDisplay.app/Contents/MacOS/VoidDisplay"]],
    ["nightly.yml", "Upload full UI artifacts", ".ai-tmp/nightly-full-ui", ["test/ui-smoke-summary.json", "test/ui-test-report.json", "test/runs/key/invocation.1/attempt-1/XcodeTests.xcresult/Data/data.0"], ["DerivedData/ModuleCache.noindex/cache.pcm", "DerivedData/Build/Products/Debug/VoidDisplay.app/Contents/MacOS/VoidDisplay"]]
];
for (const [workflow, step, root, retained, omitted, job] of fixtures) {
    const paths = uploadPaths(workflow, step, job);
    for (const file of retained) assert.ok(selected(paths, `${root}/${file}`), `${step} omitted diagnostic evidence: ${file}`);
    for (const file of omitted) assert.ok(!selected(paths, `${root}/${file}`), `${step} included disposable build files: ${file}`);
}
process.stdout.write("CI artifact path fixtures passed.\n");
