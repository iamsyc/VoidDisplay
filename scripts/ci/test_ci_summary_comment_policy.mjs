#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const workflowURL = new URL("../../.github/workflows/ci.yml", import.meta.url);
const workflow = await readFile(workflowURL, "utf8");
const lines = workflow.split(/\r?\n/);
const marker = "<!-- ci-summary-marker -->";
const leadingSpaces = (line) => line.length - line.trimStart().length;
const readScriptBlock = (scriptIndex) => {
  const scriptIndent = leadingSpaces(lines[scriptIndex]) + 2;
  const scriptLines = [];

  for (let index = scriptIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim().length === 0) {
      scriptLines.push("");
      continue;
    }
    if (leadingSpaces(line) < scriptIndent) {
      break;
    }
    scriptLines.push(line.slice(scriptIndent));
  }

  return scriptLines.join("\n");
};

const matchingScripts = lines
  .flatMap((line, index) => (/^script:\s*\|[+-]?$/.test(line.trim()) ? [readScriptBlock(index)] : []))
  .filter((candidate) => candidate.includes(marker));

assert.equal(
  matchingScripts.length,
  1,
  `Expected one inline script containing the CI summary marker, found ${matchingScripts.length}.`,
);

const [script] = matchingScripts;

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const executeScript = new AsyncFunction("core", "github", "context", script);

const restoreEnvironment = (name, previousValue) => {
  if (previousValue === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = previousValue;
  }
};

const runFixture = async ({ gateResult, hasExistingComment }) => {
  const previousGateResult = process.env.GATE_RESULT;
  const previousRunURL = process.env.RUN_URL;
  process.env.GATE_RESULT = gateResult;
  process.env.RUN_URL = "https://example.invalid/actions/runs/1";

  const commentCalls = [];
  let summaryWrites = 0;
  const summary = {
    addRaw(body) {
      assert.match(body, /## CI Summary/);
      return this;
    },
    async write() {
      summaryWrites += 1;
    },
  };
  const core = {
    summary,
    warning(message) {
      throw new Error(message);
    },
  };
  const listComments = () => {};
  const github = {
    paginate: async (operation, parameters) => {
      assert.equal(operation, listComments);
      assert.equal(parameters.issue_number, 123);
      return hasExistingComment
        ? [{ id: 7, user: { type: "Bot" }, body: marker }]
        : [];
    },
    rest: {
      issues: {
        listComments,
        async updateComment(parameters) {
          assert.equal(parameters.comment_id, 7);
          commentCalls.push("update");
        },
        async createComment(parameters) {
          assert.equal(parameters.issue_number, 123);
          commentCalls.push("create");
        },
      },
    },
  };
  const context = {
    eventName: "pull_request",
    payload: { pull_request: { number: 123 } },
    repo: { owner: "iamsyc", repo: "VoidDisplay" },
  };

  try {
    await executeScript(core, github, context);
  } finally {
    restoreEnvironment("GATE_RESULT", previousGateResult);
    restoreEnvironment("RUN_URL", previousRunURL);
  }

  assert.equal(summaryWrites, 1);
  return commentCalls;
};

const fixtures = [
  { gateResult: "success", hasExistingComment: false, expectedCalls: [] },
  { gateResult: "failure", hasExistingComment: false, expectedCalls: ["create"] },
  { gateResult: "success", hasExistingComment: true, expectedCalls: ["update"] },
  { gateResult: "failure", hasExistingComment: true, expectedCalls: ["update"] },
];

for (const fixture of fixtures) {
  const actualCalls = await runFixture(fixture);
  assert.deepEqual(
    actualCalls,
    fixture.expectedCalls,
    `Unexpected comment calls for gate=${fixture.gateResult}, existing=${fixture.hasExistingComment}.`,
  );
}

process.stdout.write("CI summary comment policy fixtures passed.\n");
