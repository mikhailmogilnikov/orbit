/**
 * The live window on the home page. States: idle (before the agent's turn), playing, review
 * (changes wait for Keep or Undo), done. Lines carry their kind in data-kind; the classes on them
 * are what the reader sees now.
 */

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const still = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

export function runDemo(win: HTMLElement) {
  const $ = <T extends HTMLElement = HTMLElement>(s: string) => win.querySelector<T>(s)!;
  const $$ = <T extends HTMLElement = HTMLElement>(s: string) => [...win.querySelectorAll<T>(s)];

  const lines = $$(".ln");
  const chat = $("[data-chat]");
  const blocks = [...new Set(lines.filter((l) => l.dataset.block).map((l) => Number(l.dataset.block)))];
  const pending = new Set<number>();
  let focus = -1;
  let run = 0;

  const linesOf = (block: number) => lines.filter((l) => Number(l.dataset.block) === block && l.dataset.block);

  // ── Lines ──

  function reset() {
    for (const line of lines) {
      line.className = `ln is-${line.dataset.kind}`;
      // Before the turn the old line is just code, and the new ones aren't written
      if (line.dataset.kind === "add") line.classList.add("is-hidden");
      if (line.dataset.kind === "del") line.classList.replace("is-del", "is-ctx");
    }
    for (const step of $$("[data-step]")) step.classList.remove("is-shown", "is-entering");
    for (const word of $$(".word")) word.classList.remove("is-on");
    for (const file of $$("[data-changed-file]")) file.classList.remove("is-gone");
    for (const extra of $$(".msg--extra")) extra.remove();
    $("[data-step='think']").classList.remove("is-over");
    $("[data-think-label]").textContent = "Thinking…";
    win.classList.remove("has-changes", "has-cache", "has-review");
    pending.clear();
    setFocus(-1);
    update();
  }

  function write(block: number) {
    for (const line of linesOf(block)) {
      line.classList.remove("is-hidden");
      if (line.dataset.kind === "del") line.classList.replace("is-ctx", "is-del");
      line.classList.add("is-arriving");
    }
    pending.add(block);
    win.classList.add("has-changes");
    update();
  }

  function settle(block: number, keep: boolean) {
    if (!pending.has(block)) return;
    for (const line of linesOf(block)) {
      line.classList.remove("is-focus", "is-arriving");
      const kind = line.dataset.kind;
      if ((kind === "add") === keep) line.classList.replace(`is-${kind}`, "is-ctx");
      else line.classList.add("is-gone");
    }
    pending.delete(block);
    if (focus === block) setFocus(blocks.find((b) => b > block && pending.has(b)) ?? blocks.find((b) => pending.has(b)) ?? -1);
    update();
    if (!pending.size) finish(keep);
  }

  function settleAll(keep: boolean) {
    for (const block of [...pending]) settle(block, keep);
  }

  function finish(keep: boolean) {
    win.classList.remove("has-changes");
    win.dataset.state = "done";
    $("[data-done-text]").textContent = keep ? "All changes reviewed" : "All changes reviewed — the file is back as it was";
  }

  /** The current change: its lines lit */
  function setFocus(block: number, scroll = false) {
    focus = block;
    for (const line of lines) line.classList.toggle("is-focus", line.dataset.block === String(block));
    if (!scroll || block === -1) return;
    const first = linesOf(block)[0];
    const code = $("[data-code]");
    code.scrollTo({ top: first.offsetTop - code.clientHeight / 3, behavior: still() ? "auto" : "smooth" });
  }

  /** Keep and Undo float under every block still waiting, as in the app */
  function showChips() {
    for (const chip of $$("[data-chip]")) {
      const block = Number(chip.dataset.chip);
      chip.classList.toggle("is-shown", pending.has(block));
      if (pending.has(block)) placeChip(chip, block);
    }
  }

  function placeChip(chip: HTMLElement, block: number) {
    const shown = linesOf(block).filter((l) => !l.classList.contains("is-gone"));
    const last = shown[shown.length - 1];
    if (last) chip.style.top = `${last.offsetTop + 21 + 3}px`;
  }

  // Lines settle in height after a change arrives or goes: keep the capsules under their blocks
  $("[data-code]").addEventListener("transitionend", showChips);

  function move(step: 1 | -1) {
    const open = blocks.filter((b) => pending.has(b));
    if (!open.length) return;
    const at = open.indexOf(focus);
    setFocus(open[at === -1 ? (step === 1 ? 0 : open.length - 1) : (at + step + open.length) % open.length], true);
  }

  /** The counts: banner, status bar, changed files */
  function update() {
    let plus = 0;
    let minus = 0;
    for (const block of pending) {
      for (const line of linesOf(block)) {
        if (line.dataset.kind === "add" && line.textContent!.trim()) plus++;
        if (line.dataset.kind === "del") minus++;
      }
    }
    $("[data-count]").textContent = String(pending.size);
    $("[data-plus]").textContent = `+${plus}`;
    $("[data-minus]").textContent = `−${minus}`;
    $("[data-minus]").hidden = minus === 0;
    $("[data-file-plus]").textContent = `+${plus}`;
    $("[data-file-minus]").textContent = `−${minus}`;
    $("[data-file-minus]").hidden = minus === 0;
    // The new cache.ts goes with the review of the client: kept or undone along with it
    for (const el of $$("[data-total-plus]")) el.textContent = `+${plus + (pending.size ? 36 : 0)}`;
    for (const el of $$("[data-total-minus]")) {
      el.textContent = `−${minus}`;
      el.hidden = minus === 0;
    }
    $("[data-files-count]").textContent = pending.size ? "2" : "0";
    // Files, not blocks: cache.ts waits from the moment it's written
    const files = pending.size ? 2 : win.classList.contains("has-cache") && win.dataset.state === "playing" ? 1 : 0;
    $("[data-status-text]").textContent = files ? `${files} to review` : "Nothing to review";
    win.classList.toggle("has-review", files > 0);
    showChips();
    if (!pending.size && win.dataset.state === "review") {
      for (const file of $$("[data-changed-file]")) file.classList.add("is-gone");
    }
  }

  // ── The agent's turn ──

  function show(step: string) {
    const el = $(`[data-step='${step}']`);
    el.classList.add("is-shown", "is-entering");
    requestAnimationFrame(() => requestAnimationFrame(() => el.classList.remove("is-entering")));
    chat.scrollTo({ top: chat.scrollHeight, behavior: still() ? "auto" : "smooth" });
    return el;
  }

  async function stream(step: string, id: number) {
    const el = show(step);
    for (const word of el.querySelectorAll(".word")) {
      if (id !== run) return;
      word.classList.add("is-on");
      chat.scrollTop = chat.scrollHeight;
      await wait(still() ? 0 : 38);
    }
  }

  async function play() {
    const id = ++run;
    reset();
    win.dataset.state = "playing";
    const alive = () => id === run;
    const pause = async (ms: number) => {
      await wait(still() ? 0 : ms);
      return alive();
    };

    show("think");
    if (!(await pause(1400))) return;
    $("[data-step='think']").classList.add("is-over");
    $("[data-think-label]").textContent = "Thought for 3s";
    await stream("intro", id);
    if (!(await pause(500))) return;
    show("read");
    if (!(await pause(900))) return;
    show("write");
    win.classList.add("has-cache");
    update();
    if (!(await pause(1000))) return;
    show("edit");
    for (const block of blocks) {
      write(block);
      if (!(await pause(420))) return;
    }
    await stream("outro", id);
    if (!alive()) return;
    show("worked");
    show("changed");
    show("usage");
    win.dataset.state = "review";
    setFocus(blocks[0]);
    update();
  }

  // Words of the agent's messages, so they can stream in
  for (const el of $$("[data-stream]")) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const texts: Text[] = [];
    while (walker.nextNode()) texts.push(walker.currentNode as Text);
    for (const text of texts) {
      const frag = document.createDocumentFragment();
      for (const part of text.data.split(/(\s+)/)) {
        if (!part) continue;
        if (/^\s+$/.test(part)) frag.append(part);
        else frag.append(Object.assign(document.createElement("span"), { className: "word", textContent: part }));
      }
      text.replaceWith(frag);
    }
  }

  // ── Input ──

  win.addEventListener("click", (event) => {
    const target = (event.target as Element).closest<HTMLElement>("button");
    if (!target) return;
    const d = target.dataset;
    if (d.keep) settle(Number(d.keep), true);
    else if (d.undo) settle(Number(d.undo), false);
    else if ("keepAll" in d) settleAll(true);
    else if ("undoAll" in d) settleAll(false);
    else if ("next" in d) move(1);
    else if ("prev" in d) move(-1);
    else if ("replay" in d) play();
    else if ("review" in d) setFocus(blocks.find((b) => pending.has(b)) ?? -1, true);
    else if (d.note) say("A note on these lines goes to the agent with your next message — in the app.");
  });

  // A tap on a change's lines makes it the current one
  const code = $("[data-code]");
  code.addEventListener("click", (e) => {
    if ((e.target as Element).closest("button")) return;
    const line = (e.target as Element).closest<HTMLElement>(".ln");
    if (line?.dataset.block !== undefined && pending.has(Number(line.dataset.block))) setFocus(Number(line.dataset.block));
  });

  // The app's own keys, while the window is on screen
  let onScreen = false;
  new IntersectionObserver(([entry]) => (onScreen = entry.intersectionRatio > 0.5), { threshold: [0, 0.5, 1] }).observe(win);
  document.addEventListener("keydown", (e) => {
    if (!onScreen || win.dataset.state !== "review" || (e.target as Element).closest("input, textarea")) return;
    const block = focus !== -1 ? focus : blocks.find((b) => pending.has(b));
    let handled = true;
    if (e.metaKey && e.shiftKey && e.key === "Enter") settleAll(true);
    else if (e.metaKey && e.shiftKey && e.key === "Backspace") settleAll(false);
    else if (e.metaKey && e.altKey && e.key === "Enter" && block !== undefined) settle(block, true);
    else if (e.metaKey && e.altKey && e.key === "Backspace" && block !== undefined) settle(block, false);
    else if (e.metaKey && e.altKey && e.key === "ArrowDown") move(1);
    else if (e.metaKey && e.altKey && e.key === "ArrowUp") move(-1);
    else handled = false;
    if (handled) e.preventDefault();
  });

  function say(text: string, user?: string) {
    if (user) chat.append(Object.assign(document.createElement("div"), { className: "msg msg--user msg--extra", textContent: user }));
    chat.append(Object.assign(document.createElement("div"), { className: "msg msg--extra", textContent: text }));
    chat.scrollTo({ top: chat.scrollHeight, behavior: "smooth" });
  }

  $<HTMLFormElement>("[data-composer]").addEventListener("submit", (e) => {
    e.preventDefault();
    const input = $<HTMLInputElement>("[data-composer] input");
    const text = input.value.trim();
    if (!text) return;
    input.value = "";
    $<HTMLButtonElement>("[data-send]").disabled = true;
    say("This window is a picture of Orbit that works. Download the app and the real Claude Code answers here.", text);
  });

  // Send is grey until there's something to send
  $<HTMLInputElement>("[data-input]").addEventListener("input", (e) => {
    $<HTMLButtonElement>("[data-send]").disabled = !(e.target as HTMLInputElement).value.trim();
  });

  // ── Start when it scrolls into view ──

  reset();
  win.dataset.state = "idle";
  const start = new IntersectionObserver(
    ([entry]) => {
      if (!entry.isIntersecting) return;
      start.disconnect();
      setTimeout(play, still() ? 0 : 500);
    },
    { threshold: 0.35 },
  );
  start.observe(win);
}
