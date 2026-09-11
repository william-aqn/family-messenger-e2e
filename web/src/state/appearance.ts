// How big the interface is drawn.
//
// app.css is a px-for-px transcript of the design handoff — 44px buttons, 64px
// headers, icons sized by SVG attribute — so growing the text on its own would
// leave it clipped inside boxes that did not grow, and beside icons that
// stayed small. `zoom` on the root grows the whole interface in proportion
// instead, text included, which is what the browser's own zoom does.
//
// Two things `zoom` does not do by itself, and this module does:
//   - viewport units keep measuring the unzoomed viewport, so `90vh` under a
//     scale of 1.3 would be 117% of the screen; the stylesheet divides them
//     back through `--vw` / `--vh`;
//   - media queries never see the scale, so the 720px breakpoint is evaluated
//     here against the width the layout actually gets, and published as
//     `:root.narrow` (app.css matches on that instead of `@media`).
import { signal } from '@preact/signals';

/** The steps the settings modal offers. 1 is the size the design draws. */
export const uiScales = [1, 1.15, 1.3, 1.45, 1.6];

/** The width, in the scaled pixels the layout sees, below which it folds into one column. */
const NARROW = 720;

const STORAGE_KEY = 'family-messenger.ui-scale';

function stored(): number {
  try {
    const saved = Number(localStorage.getItem(STORAGE_KEY));
    if (uiScales.includes(saved)) return saved;
  } catch {
    /* storage unavailable */
  }
  return 1;
}

export const uiScale = signal<number>(stored());

let narrow: MediaQueryList | null = null;

function applyNarrow(): void {
  document.documentElement.classList.toggle('narrow', narrow?.matches ?? false);
}

function apply(scale: number): void {
  document.documentElement.style.setProperty('--ui-scale', String(scale));
  narrow?.removeEventListener('change', applyNarrow);
  narrow = matchMedia(`(max-width: ${NARROW * scale}px)`);
  narrow.addEventListener('change', applyNarrow);
  applyNarrow();
}

apply(uiScale.value);

export function setUiScale(scale: number): void {
  if (!uiScales.includes(scale)) return;
  uiScale.value = scale;
  apply(scale);
  try {
    localStorage.setItem(STORAGE_KEY, String(scale));
  } catch {
    /* storage unavailable */
  }
}
