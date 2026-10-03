import "@testing-library/jest-dom/vitest";

// jsdom has no 2D canvas; the background grid draws nothing without one
HTMLCanvasElement.prototype.getContext = () => null;
