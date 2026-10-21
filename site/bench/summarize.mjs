// Turns run.sh's output into ../src/data/numbers.json for the site: every run, the app versions
// and their size on disk. usage: node summarize.mjs results.tsv [more.tsv…]
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const APPS = {
  Orbit: process.env.ORBIT ?? "/Applications/Orbit.app",
  Zed: "/Applications/Zed.app",
  "VS Code": "/Applications/Visual Studio Code.app",
  Cursor: "/Applications/Cursor.app",
};

const sh = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8" }).trim();

const runs = process.argv
  .slice(2)
  .flatMap((file) => readFileSync(file, "utf8").split("\n"))
  .map((line) => line.split("\t"))
  .filter((f) => f.length === 6 && f[1] !== "0") // run 0 is the warm-up
  .map(([app, run, launch, memory, processes, cpu]) => ({
    app,
    run: Number(run),
    launch: Number(launch),
    memory: Number(memory),
    processes: Number(processes),
    cpu: Number(cpu),
  }));

const versions = {};
const disk = {};
for (const [name, path] of Object.entries(APPS)) {
  versions[name] = sh("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", `${path}/Contents/Info.plist`]);
  disk[name] = Math.round((Number(sh("/usr/bin/du", ["-sk", path]).split("\t")[0]) * 1024) / 1_000_000);
}

const chip = sh("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]);
const memory = Math.round(Number(sh("/usr/sbin/sysctl", ["-n", "hw.memsize"])) / 2 ** 30);
const model = sh("/usr/sbin/system_profiler", ["SPHardwareDataType"]).match(/Model Name: (.*)/)?.[1] ?? "Mac";

const out = {
  date: new Date().toISOString().slice(0, 10),
  mac: `${model}, ${chip}, ${memory} GB`,
  macos: `macOS ${sh("/usr/bin/sw_vers", ["-productVersion"])}`,
  versions,
  disk,
  runs,
};
writeFileSync(new URL("../src/data/numbers.json", import.meta.url), JSON.stringify(out, null, 2) + "\n");
console.log(`${runs.length} runs, ${Object.keys(versions).length} apps`);
