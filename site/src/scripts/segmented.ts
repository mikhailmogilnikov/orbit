/**
 * A `.seg`: buttons with `data-value`, one of them `aria-pressed`, and a `.seg__thumb` that slides
 * to it. The thumb is placed from the button's box, so it follows font loading and resizes.
 */
export function segmented(seg: HTMLElement, onChange?: (value: string) => void) {
  const thumb = seg.querySelector<HTMLElement>(".seg__thumb");
  const buttons = [...seg.querySelectorAll<HTMLButtonElement>("button[data-value]")];

  const pressed = () => buttons.find((b) => b.getAttribute("aria-pressed") === "true");

  const place = (instant = false) => {
    const on = pressed();
    if (!thumb || !on) return;
    if (instant) seg.classList.add("is-instant");
    thumb.style.width = `${on.offsetWidth}px`;
    thumb.style.transform = `translateX(${on.offsetLeft}px)`;
    if (instant) {
      void thumb.offsetWidth;
      seg.classList.remove("is-instant");
    }
  };

  const select = (value: string, silent = false) => {
    for (const b of buttons) b.setAttribute("aria-pressed", String(b.dataset.value === value));
    place();
    if (!silent) onChange?.(value);
  };

  for (const b of buttons) {
    b.addEventListener("click", () => {
      if (b.getAttribute("aria-pressed") !== "true") select(b.dataset.value!);
    });
  }
  new ResizeObserver(() => place(true)).observe(seg);
  place(true);

  return { select, value: () => pressed()?.dataset.value };
}
