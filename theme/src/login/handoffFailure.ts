// The reasons a Web handoff can fail with inside SkyApp's WebView, exactly the
// `reason` codes of `/realms/{realm}/sky-handoff/v1/failed` (the SPI's
// FailureReason). Kept free of imports so the page, the dev preview, the unit
// tests and the Playwright visual spec share one list.
export const handoffFailureReasons = [
  "expired",
  "used",
  "invalid",
  "target_disabled",
  "account_unavailable",
  "unavailable"
] as const;

export type HandoffFailureReason = (typeof handoffFailureReasons)[number];

/** The reason to show for a page attribute; anything unknown is the generic `unavailable`. */
export function toHandoffFailureReason(value: unknown): HandoffFailureReason {
  return (handoffFailureReasons as readonly unknown[]).includes(value) ? (value as HandoffFailureReason) : "unavailable";
}
