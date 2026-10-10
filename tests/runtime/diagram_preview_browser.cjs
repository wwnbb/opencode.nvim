// Uses an existing Playwright/Chrome installation; never installs dependencies.
const { chromium } = require("playwright");
const { pathToFileURL } = require("node:url");
const path = require("node:path");
const fs = require("node:fs");
const directory = process.env.OPENCODE_DIAGRAM_PREVIEW_DIR;
if (!directory) throw new Error("OPENCODE_DIAGRAM_PREVIEW_DIR is required");
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.OPENCODE_CHROME || undefined });
  const report = { browser: browser.version(), mermaid: "12.1.0", katex: "0.19.0", checks: [] };
  try {
    for (const [kind, blocked] of [["mermaid", false], ["math", false], ["invalid", false], ["math", true]]) {
      const page = await browser.newPage();
      if (blocked) await page.route("https://cdn.jsdelivr.net/**", route => route.abort());
      await page.goto(pathToFileURL(path.join(directory, `${kind}.html`)).href);
      await page.waitForFunction(() => !document.getElementById("status").textContent.startsWith("Loading"));
      const result = await page.evaluate(() => ({
        status: document.getElementById("status").textContent,
        svg: document.querySelectorAll("#preview svg").length,
        math: document.querySelectorAll("#preview .katex").length,
        executed: !!globalThis.untrustedExecuted,
      }));
      const failure = blocked || kind === "invalid";
      if (result.executed || (failure ? !result.status.startsWith("Preview unavailable:")
        : kind === "mermaid" ? result.svg !== 1 : result.math !== 1)) throw new Error(JSON.stringify(result));
      if (!failure) await page.screenshot({ path: path.join(directory, `${kind}.png`) });
      console.log(JSON.stringify({ kind, blocked, status: result.status, svg: result.svg, math: result.math }));
      report.checks.push({ kind, blocked, status: result.status, svg: result.svg, math: result.math, untrustedExecuted: result.executed });
      await page.close();
    }
    fs.writeFileSync(path.join(directory, "report.json"), JSON.stringify(report, null, 2) + "\n");
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
