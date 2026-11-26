/**
 * JUnit wrapper for the idle-gate suite, for critical-remediation enrollment:
 * the engine's required-file report needs a fresh parseable JUnit XML at an
 * exact path on every run, produced by an allowlisted executable (bun). Runs
 * the real bash suite; its exit code and summary decide the testcase status.
 * The report path arrives as argv[2].
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";

const report = process.argv[2];
if (!report) {
  console.error("usage: inference-idle-gate-junit.ts <report-path>");
  process.exit(2);
}
const root = path.resolve(import.meta.dir, "..");
const suite = path.join(root, "tests", "inference-idle-gate-unit.sh");

let output = "";
let rc = 0;
try {
  output = execFileSync("bash", [suite], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
} catch (thrown) {
  const error = thrown as { status?: number; stdout?: string; stderr?: string };
  rc = typeof error.status === "number" ? error.status : 1;
  output = `${error.stdout ?? ""}${error.stderr ?? ""}`;
}
const summary = output.trimEnd().split("\n").pop() ?? "suite failed";
const failures = rc === 0 ? 0 : 1;
const esc = (s: string): string =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const name = "bash tests/inference-idle-gate-unit.sh";
const testcase = failures === 0
  ? `    <testcase name="${esc(name)}" classname="dotfiles.inference"/>\n`
  : `    <testcase name="${esc(name)}" classname="dotfiles.inference">\n` +
    `      <failure message="${esc(summary)}"><![CDATA[${output}]]></failure>\n` +
    `    </testcase>\n`;
const xml =
  `<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n` +
  `  <testsuite name="inference-idle-gate-unit" tests="1" failures="${failures}" errors="0" skipped="0">\n` +
  testcase +
  `  </testsuite>\n</testsuites>\n`;
mkdirSync(path.dirname(report), { recursive: true });
const tmp = `${report}.tmp-${process.pid}`;
writeFileSync(tmp, xml);
renameSync(tmp, report);
process.exit(rc);
