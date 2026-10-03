import { useEffect, useRef } from "react";

const CELL = 48;
const LINE = "rgba(255, 255, 255, 0.05)";
const WHITE = "255, 255, 255";
const LILAC = "224, 200, 229";
/** How many cells glow at once, per 100 cells on screen */
const DENSITY = 1.6;
/** Cells within this many cell widths of the pointer light up */
const POINTER_REACH = 3.5;

type Blink = { col: number; row: number; born: number; life: number; peak: number; tint: string };

/**
 * A grid of squares behind the login card. Random cells fade in and out, a few
 * of them in the brand lilac, and the cells around a mouse pointer light up.
 * Decoration only: hidden from assistive technology. With reduced motion the
 * grid holds still with a handful of lit cells; without a 2D canvas it is
 * simply absent.
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
    const media = (query: string) => typeof window.matchMedia === "function" && window.matchMedia(query).matches;
    const still = media("(prefers-reduced-motion: reduce)");
    const tracksPointer = media("(hover: hover) and (pointer: fine)");

    let width = 0;
    let height = 0;
    let cols = 0;
    let rows = 0;
    let blinks: Blink[] = [];
    let pointer: { x: number; y: number } | null = null;
    let frame = 0;

    const spawn = (now: number, age = 0): Blink => ({
      col: Math.floor(Math.random() * cols),
      row: Math.floor(Math.random() * rows),
      born: now - age,
      life: 2200 + Math.random() * 2600,
      peak: 0.05 + Math.random() * 0.06,
      tint: Math.random() < 0.3 ? LILAC : WHITE
    });

    const target = () => Math.max(4, Math.round(((cols * rows) / 100) * DENSITY));

    const resize = () => {
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = window.innerWidth;
      height = window.innerHeight;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      cols = Math.ceil(width / CELL) + 1;
      rows = Math.ceil(height / CELL) + 1;
      const now = performance.now();
      // Start mid-life so the first frame already shows a scattered grid
      blinks = Array.from({ length: target() }, () => {
        const blink = spawn(now);
        blink.born = now - Math.random() * blink.life;
        return blink;
      });
    };

    // The grid is centred, so the card sits on the same lines at any width
    const offsetX = () => ((width / 2) % CELL) - CELL;
    const offsetY = () => ((height / 2) % CELL) - CELL;

    const fill = (col: number, row: number, alpha: number, tint: string) => {
      if (alpha <= 0.002) return;
      ctx.fillStyle = `rgba(${tint}, ${alpha.toFixed(3)})`;
      ctx.fillRect(offsetX() + col * CELL + 1, offsetY() + row * CELL + 1, CELL - 1, CELL - 1);
    };

    const draw = (now: number) => {
      ctx.clearRect(0, 0, width, height);

      ctx.strokeStyle = LINE;
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (let x = offsetX() + 0.5; x < width; x += CELL) {
        ctx.moveTo(x, 0);
        ctx.lineTo(x, height);
      }
      for (let y = offsetY() + 0.5; y < height; y += CELL) {
        ctx.moveTo(0, y);
        ctx.lineTo(width, y);
      }
      ctx.stroke();

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
      blinks = blinks.map(blink => (now - blink.born >= blink.life ? spawn(now) : blink));
      draw(now);
      frame = requestAnimationFrame(tick);
    };

    const onPointerMove = (event: PointerEvent) => {
      pointer = { x: event.clientX, y: event.clientY };
      if (still) draw(performance.now());
    };
    const onPointerLeave = () => {
      pointer = null;
      if (still) draw(performance.now());
    };
    const onResize = () => {
      resize();
      draw(performance.now());
    };
    const onVisibility = () => {
      cancelAnimationFrame(frame);
      if (!still && document.visibilityState === "visible") frame = requestAnimationFrame(tick);
    };

    resize();
    draw(performance.now());
    if (!still) frame = requestAnimationFrame(tick);
    window.addEventListener("resize", onResize);
    document.addEventListener("visibilitychange", onVisibility);
    if (tracksPointer) {
      window.addEventListener("pointermove", onPointerMove, { passive: true });
      document.documentElement.addEventListener("pointerleave", onPointerLeave);
    }
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", onResize);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("pointermove", onPointerMove);
      document.documentElement.removeEventListener("pointerleave", onPointerLeave);
    };
  }, []);

  return <canvas ref={canvasRef} className="sl-legacy-grid" aria-hidden="true" />;
}
