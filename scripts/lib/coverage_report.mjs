import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const metricNames = ["lines", "functions", "regions"];
const percentage = metric => metric.count ? 100 * metric.covered / metric.count : null;

export function coverageReport(llvm, root, baseline = null) {
    if (llvm.type !== "llvm.coverage.json.export" || !Array.isArray(llvm.data)) throw new Error("Invalid LLVM coverage export");
    const modules = {};
    const files = [];
    for (const entry of llvm.data) {
        for (const file of entry.files) {
            const relative = path.relative(root, file.filename);
            const module = relative.match(/^Sources\/([^/]+)\//)?.[1];
            if (!module) continue;
            const metrics = {};
            modules[module] ??= Object.fromEntries(metricNames.map(name => [name, { count: 0, covered: 0 }]));
            for (const name of metricNames) {
                const value = file.summary[name];
                if (!value || !Number.isFinite(value.count) || !Number.isFinite(value.covered) || value.covered < 0 || value.count < value.covered) throw new Error(`Invalid ${name} coverage: ${relative}`);
                metrics[name] = { count: value.count, covered: value.covered, percent: percentage(value) };
                modules[module][name].count += value.count;
                modules[module][name].covered += value.covered;
            }
            // LLVM segments identify uncovered region starts, not every source line.
            const uncovered = [...new Set((file.segments ?? []).filter(segment => segment[2] === 0 && segment[3] && segment[4] && !segment[5]).map(segment => segment[0]))].sort((a, b) => a - b);
            files.push({ path: relative, module, metrics, uncovered_region_starts: uncovered });
        }
    }
    if (!files.length) throw new Error("Coverage export contains no project source files");
    for (const [module, metrics] of Object.entries(modules)) {
        for (const name of metricNames) {
            const metric = metrics[name];
            metric.percent = percentage(metric);
            const previous = baseline?.modules?.[module]?.[name]?.percent;
            metric.delta_percentage_points = typeof previous === "number" && metric.percent !== null ? metric.percent - previous : null;
        }
    }
    return { schema_version: 1, baseline_revision: baseline?.revision ?? null, modules, files: files.sort((a, b) => a.path.localeCompare(b.path)) };
}

export function coverageMarkdown(report) {
    const format = metric => metric.percent === null ? "n/a" : `${metric.percent.toFixed(2)}% (${metric.covered}/${metric.count})`;
    const delta = metric => metric.delta_percentage_points === null ? "baseline unavailable" : `${metric.delta_percentage_points >= 0 ? "+" : ""}${metric.delta_percentage_points.toFixed(2)} pp`;
    const rows = Object.entries(report.modules).sort().map(([name, metrics]) => `| ${name} | ${format(metrics.lines)} | ${delta(metrics.lines)} | ${format(metrics.functions)} | ${format(metrics.regions)} |`);
    const uncovered = report.files.filter(file => file.metrics.lines.covered < file.metrics.lines.count)
        .sort((a, b) => (b.metrics.lines.count - b.metrics.lines.covered) - (a.metrics.lines.count - a.metrics.lines.covered)).slice(0, 30)
        .map(file => `| ${file.path} | ${file.metrics.lines.count - file.metrics.lines.covered} | ${file.uncovered_region_starts.slice(0, 20).join(", ") || "see LLVM export"} |`);
    return `# Swift module coverage\n\nRevision: ${report.revision ?? "unknown"}. Source fingerprint: ${report.source_fingerprint ?? "unavailable"}. Compared with: ${report.baseline_revision ?? "none (first baseline)"}.\n\nSwiftPM coverage measures executed source, including SwiftUI code reached by unit tests. UI acceptance, JavaScript and Go coverage are separate evidence. No global percentage gate is applied.\n\n| Module | Lines | Change | Functions | Regions |\n| --- | ---: | ---: | ---: | ---: |\n${rows.join("\n")}\n\n## Largest uncovered source areas\n\nUp to 30 files and 20 region starts per file are shown. The JSON report contains every file and uncovered region start.\n\n| File | Uncovered lines | Uncovered region start lines |\n| --- | ---: | --- |\n${uncovered.join("\n")}\n`;
}

if (existsSync(process.argv[1] ?? "") && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
    const [input, root, baselinePath, output, revision, sourceFingerprint] = process.argv.slice(2);
    const baseline = existsSync(baselinePath) ? JSON.parse(readFileSync(baselinePath, "utf8")) : null;
    if (baseline && baseline.schema_version !== 1) throw new Error("Unsupported coverage baseline schema");
    const report = { ...coverageReport(JSON.parse(readFileSync(input, "utf8")), realpathSync(root), baseline), revision, source_fingerprint: sourceFingerprint };
    writeFileSync(`${output}.json`, JSON.stringify(report, null, 2) + "\n");
    writeFileSync(`${output}.md`, coverageMarkdown(report));
}
