import { existsSync, readFileSync, realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const target = "VoidDisplayUITests";
const home = `${target}/HomeSmokeTests/testHomeCoreJourney`;
export const suiteMappings = [
    ["Sources/VoidDisplayApp/Navigation/MenuBar", ["MenuBarQuickActionsSmokeTests"]],
    ["Sources/VoidDisplayApp/Navigation/AppSettings", ["FeedbackSettingsTests"]],
    ["Sources/VoidDisplayApp/Navigation/Home", ["HomeSmokeTests", "VirtualDisplaySmokeTests"]],
    ["Sources/VoidDisplayVirtualDisplay/", ["VirtualDisplaySmokeTests", "HomeSmokeTests", "MenuBarQuickActionsSmokeTests"]],
    ["Sources/VoidDisplayCGVirtualDisplay/", ["VirtualDisplaySmokeTests"]],
    ["Sources/VoidDisplayCapture/", ["PreviewSmokeTests", "MenuBarQuickActionsSmokeTests"]],
    ["Sources/VoidDisplaySharing/", ["HomeSmokeTests", "MenuBarQuickActionsSmokeTests"]],
    ["Sources/VoidDisplaySupport/", ["DiagnosticsSmokeTests", "FeedbackSettingsTests"]]
];

export function selectUITests(paths, readSource) {
    if (paths.length === 0) return [target];
    const selected = new Set([home]);
    for (const changedPath of paths) {
        if (/^(docs|Tests)\//.test(changedPath) || /^(README[^/]*|AGENTS\.md|LICENSE[^/]*)$/.test(changedPath)) continue;
        if (changedPath.startsWith("UITests/")) {
            let source;
            try { source = readSource(changedPath); } catch { return [target]; }
            const classes = [...source.matchAll(/(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b/g)];
            if (classes.length !== 1) return [target];
            const className = classes[0][1];
            selected.add(`${target}/${className}`);
            continue;
        }
        const mapping = suiteMappings.find(([prefix]) => changedPath.startsWith(prefix));
        if (!mapping) return [target];
        for (const suite of mapping[1]) selected.add(`${target}/${suite}`);
    }
    // A suite selector already contains all its methods.
    return [...selected].filter(selector => ![...selected].some(parent => selector.startsWith(`${parent}/`))).sort();
}

if (existsSync(process.argv[1] ?? "") && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
    const [root, filesJSON] = process.argv.slice(2);
    const selected = selectUITests(JSON.parse(filesJSON), relative => readFileSync(path.join(root, relative), "utf8"));
    process.stdout.write(`${JSON.stringify(selected)}\n`);
}
