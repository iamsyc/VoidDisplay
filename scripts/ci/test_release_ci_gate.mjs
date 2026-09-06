#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(new URL("../../.github/workflows/release.yml", import.meta.url), "utf8");
const gateJob = workflow.split("  require_ci_gate:\n")[1].split(/^  \w+:/m)[0];
const script = gateJob.split("          script: |\n")[1].split(/^      - name:/m)[0]
    .split("\n").map(line => line.slice(12)).join("\n");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const execute = new AsyncFunction("core", "github", "context", "require", "process", "Date", "setTimeout", script);
const target = "a".repeat(40);
const other = "b".repeat(40);

function run(overrides = {}) {
    const result = {
        id: 1, path: ".github/workflows/ci.yml", head_branch: "main", event: "push", head_sha: target,
        status: "completed", conclusion: "success", run_attempt: 1, ...overrides
    };
    result.created_at = new Date(result.id * 100000).toISOString();
    result.jobs ??= [{
        id: result.id * 10, name: "ci-gate", status: result.status, conclusion: result.conclusion,
        head_sha: result.head_sha, run_attempt: result.run_attempt, started_at: result.created_at
    }];
    return result;
}

async function evaluate(frames) {
    let tick = 0;
    let now = 0;
    let summary;
    let error;
    let mainReads = 0;
    let comparisons = 0;
    const frame = () => frames[Math.min(tick, frames.length - 1)];
    const github = { rest: {
        actions: {
            async listWorkflowRuns(args) {
                assert.equal(args.workflow_id, "ci.yml");
                assert.equal(args.head_sha, target);
                assert.equal(args.branch, "main");
                assert.equal(args.event, "push");
                if (frame().apiError) throw frame().apiError;
                return { data: { workflow_runs: (frame().runs ?? []).filter(item =>
                    item.path === `.github/workflows/${args.workflow_id}` && item.head_sha === args.head_sha
                    && item.head_branch === args.branch && item.event === args.event) } };
            },
            async listJobsForWorkflowRun(args) {
                assert.equal(args.filter, "latest");
                const selected = frame().runs.find(item => item.id === args.run_id);
                assert.ok(selected, "Jobs must belong to the selected workflow run.");
                return { data: { jobs: selected.jobs } };
            }
        },
        checks: {
            async listForRef() { return { data: { check_runs: (frame().runs ?? []).flatMap(item => item.jobs) } }; }
        },
        repos: {
            async getCombinedStatusForRef() { return { data: { statuses: frame().statuses ?? [] } }; },
            async getBranch() {
                mainReads++;
                if (frame().mainError) throw frame().mainError;
                assert.ok(frame().runs.some(item => item.event === "push" && item.status === "completed"),
                    "Main ancestry must be refreshed after the CI wait.");
                return { data: { commit: { sha: frame().main ?? target } } };
            },
            async compareCommits(args) {
                comparisons++;
                assert.equal(args.base, target);
                assert.equal(args.head, frame().main);
                return { data: { merge_base_commit: { sha: frame().mergeBase ?? target } } };
            }
        }
    }, async paginate(method, args) {
        const { data } = await method(args);
        return data.workflow_runs ?? data.jobs;
    } };
    const fs = { async mkdir() {}, async writeFile(_path, text) { summary = JSON.parse(text); } };
    try {
        await execute({ info() {} }, github, { repo: { owner: "fixture", repo: "fixture" } },
            name => name === "fs/promises" ? fs : { dirname: () => "." },
            { env: { TARGET_SHA: target, CHECK_NAME: "ci-gate", TIMEOUT_SECONDS: "2", POLL_INTERVAL_SECONDS: "1", SUMMARY_PATH: "summary.json" } },
            class extends Date { static now() { return now; } },
            callback => { tick++; now += 1000; callback(); });
    } catch (caught) { error = caught; }
    assert.ok(summary, `The gate must record its terminal result: ${error?.message ?? "missing summary"}`);
    return { summary, error, ticks: tick, mainReads, comparisons };
}

function failed(result, reason) {
    assert.ok(result.error, "The release gate unexpectedly accepted this target.");
    assert.equal(result.summary.status, "failed");
    assert.equal(result.summary.reason, reason);
}

test("a newer static PR success cannot override a failed main push", async () => {
    failed(await evaluate([{ runs: [run({ conclusion: "failure" }), run({ id: 2, event: "pull_request" })] }]), "ci_gate_failure");
});

test("an unrelated workflow, branch, event or SHA cannot provide release evidence", async () => {
    const candidates = [
        run({ event: "pull_request" }), run({ event: "workflow_dispatch" }),
        run({ head_branch: "topic" }), run({ head_sha: other }), run({ path: ".github/workflows/nightly.yml" })
    ];
    for (const candidate of candidates) failed(await evaluate([{ runs: [candidate] }]), "ci_gate_timeout");
});

test("a generic commit status cannot substitute for the main workflow", async () => {
    failed(await evaluate([{ statuses: [{ context: "ci-gate", state: "success", created_at: "2026-09-06T00:00:00Z" }] }]), "ci_gate_timeout");
});

test("a removed main target fails after its pending CI finishes", async () => {
    const result = await evaluate([
        { runs: [run({ status: "in_progress", conclusion: null, jobs: [] })] },
        { runs: [run()], main: other, mergeBase: other }
    ]);
    failed(result, "ci_gate_target_not_on_main");
    assert.equal(result.mainReads, 1);
    assert.equal(result.comparisons, 1);
});

test("normal main advancement keeps an ancestor eligible after CI", async () => {
    const result = await evaluate([
        { runs: [run({ status: "in_progress", conclusion: null, jobs: [] })] },
        { runs: [run()], main: other, mergeBase: target }
    ]);
    assert.equal(result.error, undefined);
    assert.equal(result.summary.status, "passed");
    assert.equal(result.ticks, 1);
    assert.equal(result.mainReads, 1);
    assert.equal(result.comparisons, 1);
});

test("a newer failed main run supersedes an older success", async () => {
    failed(await evaluate([{ runs: [run(), run({ id: 2, conclusion: "failure" })] }]), "ci_gate_failure");
});

test("a rerun waits even while a previous attempt has a successful gate", async () => {
    const previousGate = run().jobs;
    const result = await evaluate([
        { runs: [run({ status: "in_progress", conclusion: null, run_attempt: 2, jobs: previousGate })] },
        { runs: [run({ run_attempt: 2 })] }
    ]);
    assert.equal(result.error, undefined);
    assert.equal(result.summary.status, "passed");
    assert.equal(result.ticks, 1);
});

test("a completed main run must contain a successful ci-gate", async () => {
    for (const conclusion of ["failure", "cancelled", "skipped", "neutral", "timed_out"])
        failed(await evaluate([{ runs: [run({ conclusion })] }]), "ci_gate_failure");
    failed(await evaluate([{ runs: [run({ jobs: [] })] }]), "ci_gate_failure");
});

test("API failures cannot be interpreted as passing evidence", async () => {
    const unavailable = Object.assign(new Error("API unavailable"), { status: 503 });
    failed(await evaluate([{ apiError: unavailable, runs: [run()] }]), "ci_gate_api_error");
    failed(await evaluate([{ mainError: unavailable, runs: [run()] }]), "ci_gate_api_error");
});

test("accepted evidence records its workflow run and refreshed main SHA", async () => {
    const result = await evaluate([{ runs: [run()] }]);
    assert.equal(result.error, undefined);
    assert.equal(result.summary.status, "passed");
    assert.equal(result.summary.workflow_run_id, 1);
    assert.equal(result.summary.workflow_run_attempt, 1);
    assert.equal(result.summary.job_id, 10);
    assert.equal(result.summary.main_sha, target);
});
