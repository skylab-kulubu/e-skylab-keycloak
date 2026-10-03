import { useEffect, useRef } from "react";

const CELL = 48;
const WHITE = "255, 255, 255";
const LILAC = "224, 200, 229";
/** How many cells glow at once, per 100 cells on screen */
const DENSITY = 1.6;
/** Cells within this many cell widths of the pointer light up */
const POINTER_REACH = 3.5;
/** The cells fade over seconds, so about 15 frames a second is plenty */
const FRAME_MS = 66;

type Blink = { col: number; row: number; born: number; life: number; peak: number; tint: string };

type NetworkInformation = { saveData?: boolean };

/**
 * A grid of squares behind the login card. Random cells fade in and out, a few
 * of them in the brand lilac, and the cells around a mouse pointer light up.
 * Decoration only: hidden from assistive technology.
 *
 * The lines are the canvas's CSS background, drawn once; the canvas itself only
 * paints the lit cells, at about 15 frames a second, because the glass card
 * above it re-blurs whatever changes underneath. Touch screens, small CPUs,
 * data saver and reduced motion get the grid once, still. A hidden canvas
 * (forced colors) never starts the loop.
 */
export default function GridBackdrop() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    let context: CanvasRenderingContext2D | null = null;
    try {
      context = canvas?.getContext("2d") ?? null;
    } catch {
      context = null;
    }
    if (canvas === null || context === null) {
      return;
    }
    const ctx = context;
    const query = (text: string) => (typeof window.matchMedia === "function" ? window.matchMedia(text) : null);
    const reducedMotion = query("(prefers-reduced-motion: reduce)");
    const forcedColors = query("(forced-colors: active)");
    const finePointer = query("(hover: hover) and (pointer: fine)");
    const lowPower =
      (navigator.hardwareConcurrency !== undefined && navigator.hardwareConcurrency <= 4) ||
      (navigator as Navigator & { connection?: NetworkInformation }).connection?.saveData === true;

    let width = 0;
    let height = 0;
    let cols = 0;
    let rows = 0;
    let blinks: Blink[] = [];
    let pointer: { x: number; y: number } | null = null;
    let frame = 0;
    let lastDraw = 0;
    let running = false;

    const animated = () => !reducedMotion?.matches && finePointer?.matches === true && !lowPower;
    const hidden = () => getComputedStyle(canvas).display === "none" || document.visibilityState !== "visible";

    const spawn = (now: number): Blink => ({
      col: Math.floor(Math.random() * cols),
      row: Math.floor(Math.random() * rows),
      born: now,
      life: 2200 + Math.random() * 2600,
      peak: 0.05 + Math.random() * 0.06,
      tint: Math.random() < 0.3 ? LILAC : WHITE
    });

    // The grid is centred, so the card sits on the same lines at any width
    const offsetX = () => ((width / 2) % CELL) - CELL;
    const offsetY = () => ((height / 2) % CELL) - CELL;

    const resize = () => {
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = window.innerWidth;
      height = window.innerHeight;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      canvas.style.backgroundPosition = `${offsetX()}px ${offsetY()}px`;

      const nextCols = Math.ceil(width / CELL) + 1;
      const nextRows = Math.ceil(height / CELL) + 1;
      // A browser bar sliding in and out resizes the page without changing the grid
      if (nextCols === cols && nextRows === rows) return;
      cols = nextCols;
      rows = nextRows;
      const now = performance.now();
      const count = Math.max(4, Math.round(((cols * rows) / 100) * DENSITY));
      // Start mid-life so the first frame already shows a scattered grid
      blinks = Array.from({ length: count }, () => {
        const blink = spawn(now);
        blink.born = now - Math.random() * blink.life;
        return blink;
      });
    };

    const fill = (col: number, row: number, alpha: number, tint: string) => {
      if (alpha <= 0.002) return;
      ctx.fillStyle = `rgba(${tint}, ${alpha.toFixed(3)})`;
      ctx.fillRect(offsetX() + col * CELL + 1, offsetY() + row * CELL + 1, CELL - 1, CELL - 1);
    };

    const draw = (now: number) => {
      lastDraw = now;
      ctx.clearRect(0, 0, width, height);
      for (const blink of blinks) {
        const t = Math.min(1, (now - blink.born) / blink.life);
        fill(blink.col, blink.row, blink.peak * Math.sin(Math.PI * t), blink.tint);
      }
      if (pointer !== null) {
        const pointerCol = (pointer.x - offsetX()) / CELL;
        const pointerRow = (pointer.y - offsetY()) / CELL;
        const reach = Math.ceil(POINTER_REACH);
        for (let row = Math.floor(pointerRow) - reach; row <= Math.floor(pointerRow) + reach; row++) {
          for (let col = Math.floor(pointerCol) - reach; col <= Math.floor(pointerCol) + reach; col++) {
            const distance = Math.hypot(col + 0.5 - pointerCol, row + 0.5 - pointerRow);
            fill(col, row, 0.09 * Math.max(0, 1 - distance / POINTER_REACH) ** 2, LILAC);
          }
        }
      }
    };

    const tick = (now: number) => {
      frame = requestAnimationFrame(tick);
      if (now - lastDraw < FRAME_MS) return;
      blinks = blinks.map(blink => (now - blink.born >= blink.life ? spawn(now) : blink));
      draw(now);
    };

    // Start or stop the loop to match the current preferences and visibility
    const update = () => {
      const run = animated() && !hidden();
      if (run && !running) {
        running = true;
        frame = requestAnimationFrame(tick);
      } else if (!run && running) {
        running = false;
        cancelAnimationFrame(frame);
      }
      if (!running && !hidden()) draw(performance.now());
    };

    const onPointerMove = (event: PointerEvent) => {
      pointer = { x: event.clientX, y: event.clientY };
      if (!running) draw(performance.now());
    };
    const onPointerLeave = () => {
      pointer = null;
      if (!running) draw(performance.now());
    };
    const onResize = () => {
      resize();
      draw(performance.now());
    };

    resize();
    update();
    window.addEventListener("resize", onResize);
    document.addEventListener("visibilitychange", update);
    reducedMotion?.addEventListener("change", update);
    forcedColors?.addEventListener("change", update);
    if (finePointer?.matches) {
      window.addEventListener("pointermove", onPointerMove, { passive: true });
      document.documentElement.addEventListener("pointerleave", onPointerLeave);
    }
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", onResize);
      document.removeEventListener("visibilitychange", update);
      reducedMotion?.removeEventListener("change", update);
      forcedColors?.removeEventListener("change", update);
      window.removeEventListener("pointermove", onPointerMove);
      document.documentElement.removeEventListener("pointerleave", onPointerLeave);
    };
  }, []);

  return <canvas ref={canvasRef} className="sl-legacy-grid" aria-hidden="true" />;
}
