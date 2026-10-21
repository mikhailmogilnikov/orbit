/**
 * The measurements behind the home page's bars and /numbers: numbers.json, written by
 * bench/summarize.mjs from bench/run.sh's runs. Medians of the runs after a warm-up.
 */
import data from "./numbers.json";

export interface Metric {
  headline: string;
  note: string;
  unit: string;
  digits?: number;
  /** Orbit first, then the others from least to most */
  rows: { app: string; value: number }[];
}

export const setup = {
  ...data,
  versions: data.versions as Record<string, string>,
  project: "18 files, a git repository",
};
export const runs = data.runs.filter((r) => r.app !== "Orbit+agent");

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};

const apps = [...new Set(runs.map((r) => r.app))];
const of = (app: string, key: "launch" | "memory" | "processes" | "cpu") =>
  median(data.runs.filter((r) => r.app === app).map((r) => r[key]));

function rows(value: (app: string) => number) {
  const [orbit, ...rest] = apps.map((app) => ({ app, value: value(app) }));
  return [orbit, ...rest.sort((a, b) => a.value - b.value)];
}

const disk = rows((app) => data.disk[app as keyof typeof data.disk]);
const launch = rows((app) => Math.round(of(app, "launch")));
const memory = rows((app) => Math.round(of(app, "memory")));
const processes = rows((app) => of(app, "processes"));
const idle = rows((app) => Math.round(of(app, "cpu") * 100) / 100);

const most = (list: { app: string; value: number }[]) => list[list.length - 1];
const fastest = launch.reduce((a, b) => (b.value < a.value ? b : a));

export const metrics: Record<"disk" | "launch" | "memory" | "processes" | "idle", Metric> = {
  disk: {
    headline: `${disk[0].value} MB on disk.`,
    note: "The text, the windows and the controls are the Mac's own; no browser engine inside to carry.",
    unit: "MB",
    rows: disk,
  },
  launch: {
    headline: `${launch[0].value} ms to the first window.`,
    note:
      fastest.app === "Orbit"
        ? "Launched with its files in the disk cache, a project opening with it."
        : `${fastest.app} is quicker here. Launched with the files in the disk cache, a project opening with it.`,
    unit: "ms",
    rows: launch,
  },
  memory: {
    headline: `${memory[0].value} MB with a project open.`,
    note: "Every process the app owns, 15 seconds in; agents aside.",
    unit: "MB",
    rows: memory,
  },
  processes: {
    headline: `${processes[0].value} processes.`,
    note: `The app and the terminal's shell. ${most(processes).app} runs ${most(processes).value}.`,
    unit: "",
    rows: processes,
  },
  idle: {
    headline: `${idle[0].value.toFixed(2)} s of CPU in a quiet half minute.`,
    note: "All of its processes together, with nobody touching anything.",
    unit: "s",
    digits: 2,
    rows: idle,
  },
};

/** Orbit with the agent it starts, for the footnote */
export const agent = {
  memory: Math.round(of("Orbit+agent", "memory")),
  processes: of("Orbit+agent", "processes"),
};
