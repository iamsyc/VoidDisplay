#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const workflow = readFileSync(new URL("../../.github/workflows/release.yml", import.meta.url), "utf8");
const resolver = workflow.split("  resolve_release_target:\n")[1].split(/^  \w+:/m)[0];
const script = resolver.split("          script: |\n")[1].split(/^      - name:/m)[0]
    .split("\n").map(line => line.slice(12)).join("\n");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const execute = new AsyncFunction("core", "github", "context", "require", "process", "Buffer", script);
const current = "a".repeat(40);
const previous = "b".repeat(40);
const other = "c".repeat(40);
const missing = () => Object.assign(new Error("Not Found"), { status: 404 });

async function resolve(overrides = {}) {
    const fixture = { event: "push", version: "1.2.3", build: "7", previousVersion: "1.2.3", previousBuild: "7", tagSHA: previous, releaseExists: false, ancestor: true, ...overrides };
    const outputs = {};
    let summary;
    const github = { rest: { git: {
        async getRef({ ref }) {
            assert.match(ref, /^tags\/v\d+\.\d+\.\d+$/);
            if (fixture.refError) throw fixture.refError;
            if (!fixture.tagSHA) throw missing();
            return { data: { ref: `refs/${ref}` } };
        }
    }, repos: {
        async getBranch() { return { data: { commit: { sha: current } } }; },
        async getCommit({ ref }) {
            if (/^tags\//.test(ref)) throw Object.assign(new Error("No commit found for SHA"), { status: 422 });
            if (!ref.startsWith("refs/tags/") && fixture.branchSHA) return { data: { sha: fixture.branchSHA } };
            assert.match(ref, /^refs\/tags\/v\d+\.\d+\.\d+$/);
            if (!fixture.tagSHA) throw missing();
            return { data: { sha: fixture.tagSHA } };
        },
        async getContent({ path, ref }) {
            assert.equal(path, "VoidDisplay.xcodeproj/project.pbxproj");
            assert.ok([current, previous, other].includes(ref));
            if (fixture.contentError) throw fixture.contentError;
            const old = fixture.event === "push" && ref === previous;
            const version = old ? fixture.previousVersion : fixture.version;
            const build = old ? fixture.previousBuild : fixture.build;
            const content = `MARKETING_VERSION = ${version};\nCURRENT_PROJECT_VERSION = ${build};\n${fixture.extraProjectLine ?? ""}`;
            return { data: { type: "file", encoding: "base64", content: Buffer.from(content).toString("base64") } };
        },
        async getReleaseByTag() {
            if (!fixture.releaseExists) throw missing();
            return { data: { id: 1 } };
        },
        async compareCommits() { return { data: { merge_base_commit: { sha: fixture.ancestor ? fixture.tagSHA : other } } }; }
    } } };
    const fs = {
        async mkdir() {},
        async writeFile(_path, contents) { summary = JSON.parse(contents); }
    };
    await execute(
        { setOutput(name, value) { outputs[name] = value; } }, github,
        { repo: { owner: "example", repo: "fixture" } },
        name => name === "fs/promises" ? fs : { dirname: () => "." },
        { env: {
            EVENT_NAME: fixture.event, INPUT_TAG: fixture.inputTag ?? (fixture.event === "workflow_dispatch" ? "v1.2.3" : ""),
            PUSH_SHA: current, BEFORE_SHA: previous, WORKFLOW_REF: fixture.ref ?? "refs/heads/main", SUMMARY_PATH: "summary.json"
        } }, Buffer
    );
    assert.ok(summary, "The resolver must write its decision summary.");
    assert.equal(summary.should_run, outputs.should_run === "true");
    return outputs;
}

assert.equal((await resolve()).should_run, "false", "An unchanged published version must skip the CI wait.");
assert.equal((await resolve({ tagSHA: null })).should_run, "true", "A missing tag must allow recovery of the current version.");
assert.equal((await resolve({ tagSHA: null, branchSHA: previous })).should_run, "true", "A branch named like a version must not count as a release tag.");
const newVersion = await resolve({ version: "1.2.4", build: "8", tagSHA: null });
assert.equal(newVersion.should_run, "true");
assert.equal(newVersion.tag, "v1.2.4");
assert.equal(newVersion.target_sha, current);
assert.equal(newVersion.build_number, "8");
await assert.rejects(resolve({ version: "1.2.4", build: "7", tagSHA: null }), /increase/i);
await assert.rejects(resolve({ version: "1.2.4", build: "8", tagSHA: other }), /already points|conflict/i);
await assert.rejects(resolve({ version: "invalid" }), /MARKETING_VERSION|version/i);
await assert.rejects(resolve({ extraProjectLine: "MARKETING_VERSION = 9.9.9;\n" }), /unique|MARKETING_VERSION/i);
await assert.rejects(resolve({ contentError: Object.assign(new Error("API unavailable"), { status: 503 }) }), /API unavailable/);
await assert.rejects(resolve({ refError: Object.assign(new Error("API unavailable"), { status: 503 }) }), /API unavailable/);
assert.equal((await resolve({ event: "workflow_dispatch", releaseExists: true })).should_run, "false");
assert.equal((await resolve({ event: "workflow_dispatch", releaseExists: true, contentError: missing() })).should_run, "false", "Published releases must skip before reading target build metadata.");
assert.equal((await resolve({ event: "workflow_dispatch", tagSHA: null })).should_run, "true");
assert.equal((await resolve({ event: "workflow_dispatch" })).target_sha, previous);
await assert.rejects(resolve({ event: "workflow_dispatch", inputTag: "v1.2.4" }), /does not match/);
await assert.rejects(resolve({ event: "workflow_dispatch", ancestor: false }), /ancestor/);
await assert.rejects(resolve({ event: "workflow_dispatch", ref: "refs/heads/topic" }), /main/);

const ci = readFileSync(new URL("../../.github/workflows/ci.yml", import.meta.url), "utf8");
const concurrency = ci.split("concurrency:\n")[1].split("\n\njobs:")[0];
function evaluate(value, github) {
    return value.replace(/\$\{\{\s*(.*?)\s*\}\}/g, (_match, expression) => new Function("github", `return (${expression});`)(github));
}
const group = concurrency.match(/^  group: (.+)$/m)[1];
const cancel = concurrency.match(/^  cancel-in-progress: (.+)$/m)[1];
const context = (sha, number) => ({ workflow: "CI", sha, ref: "refs/heads/main", event_name: number ? "pull_request" : "push", event: { pull_request: { number } } });
assert.notEqual(evaluate(group, context(current)), evaluate(group, context(previous)), "Separate main commits must keep independent CI results.");
assert.equal(evaluate(group, context(current, 1)), evaluate(group, context(previous, 1)), "An updated PR must reuse its cancellation group.");
assert.equal(evaluate(cancel, context(current)), "false");
assert.equal(evaluate(cancel, context(current, 1)), "true");
assert.match(workflow, /if:.*needs\.resolve_release_target\.outputs\.should_run == 'true'/);
assert.doesNotMatch(workflow, /^  prepare_release:/m, "Release eligibility must have one owner before the CI wait.");
process.stdout.write("Release target and CI concurrency fixtures passed.\n");
