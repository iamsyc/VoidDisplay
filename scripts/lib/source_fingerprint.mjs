import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { lstatSync, readFileSync, readlinkSync } from "node:fs";
import path from "node:path";

const [root, scope = "all"] = process.argv.slice(2);
if (!root || !["all", "xcode"].includes(scope)) {
    throw new Error("Expected repository root and fingerprint scope: all or xcode.");
}

const paths = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], {
    cwd: root,
    maxBuffer: 16 * 1024 * 1024
}).toString().split("\0").filter(Boolean);
const hash = createHash("sha256");
hash.update(`voiddisplay-content-v2:${scope}\0`);
for (const relative of [...new Set(paths)].sort()) {
    if (scope === "xcode" && (
        /^(docs|Tests|\.github)\//.test(relative)
        || /^(README[^/]*|AGENTS\.md|LICENSE[^/]*)$/.test(relative)
    )) continue;
    const absolute = path.join(root, relative);
    let stat;
    try {
        stat = lstatSync(absolute);
    } catch (error) {
        if (error.code === "ENOENT") continue;
        throw error;
    }
    if (!stat.isFile() && !stat.isSymbolicLink()) {
        throw new Error(`Unsupported repository input: ${relative}`);
    }
    hash.update(`${relative}\0${stat.mode & 0o111}\0`);
    if (stat.isSymbolicLink()) {
        hash.update(`symlink\0${readlinkSync(absolute)}\0`);
    } else {
        hash.update("file\0");
    }
    // A fixed-size digest keeps arbitrary bytes from impersonating file metadata.
    // Reading through links also tracks content changes in their targets.
    hash.update(createHash("sha256").update(readFileSync(absolute)).digest());
    hash.update("\0");
}
process.stdout.write(`${hash.digest("hex")}\n`);
