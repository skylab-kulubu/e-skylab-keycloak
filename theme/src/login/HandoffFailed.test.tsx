import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import KcPage from "./KcPage";
import type { KcContext } from "./KcContext";
import { handoffFailureReasons, toHandoffFailureReason } from "./handoffFailure";

type FailedContext = Extract<KcContext, { pageId: "sky-handoff-failed.ftl" }>;

// The Turkish copy is fixed by the Web handoff spec and matches the SPI's FailureReason.
const turkish = {
  expired: "Bağlantının süresi doldu.",
  used: "Bu bağlantı zaten kullanıldı.",
  invalid: "Bağlantı geçersiz.",
  target_disabled: "Bu siteye uygulamadan geçiş şu an kapalı.",
  account_unavailable: "Hesabın şu an kullanılamıyor.",
  unavailable: "Geçici bir sorun oluştu."
} as const;

async function renderFailure(reason: string | undefined, languageTag: "tr" | "en" = "tr") {
  const kcContext = getDevKcContextForPage("sky-handoff-failed.ftl", languageTag) as FailedContext;
  kcContext.skyHandoffReason = reason;
  const view = render(<KcPage kcContext={kcContext} />);

  await waitFor(() => {
    expect(view.container.querySelector(".sl-legacy-shell")).toHaveAttribute("data-sl-translations", "ready");
    expect(view.container.querySelector("h1")).not.toBeNull();
  });

  return view;
}

describe("Web handoff failure page", () => {
  beforeAll(() => {
    window.history.replaceState(null, "", "/?viewMode=docs");
  });

  afterEach(() => {
    cleanup();
    document.body.className = "";
    document.documentElement.className = "";
  });

  it("knows exactly the SPI's reason codes and treats anything else as unavailable", () => {
    expect([...handoffFailureReasons]).toEqual(Object.keys(turkish));
    expect(toHandoffFailureReason("used")).toBe("used");
    expect(toHandoffFailureReason("USED")).toBe("unavailable");
    expect(toHandoffFailureReason("<script>alert(1)</script>")).toBe("unavailable");
    expect(toHandoffFailureReason(undefined)).toBe("unavailable");
    expect(toHandoffFailureReason(42)).toBe("unavailable");
  });

  it.each(handoffFailureReasons)("%s shows its own Turkish sentence and the retry hint", async reason => {
    const { container } = await renderFailure(reason);

    expect(container.querySelector("h1")).toHaveTextContent(turkish[reason]);
    expect(container.querySelector("h1")?.textContent).toBe(turkish[reason]);
    expect(container.querySelector(".sl-legacy-intro p")?.textContent).toBe("Uygulamaya dönüp tekrar dene.");
    expect(container.querySelector("main")).toHaveAttribute("id", "sl-handoff-failed-main");
    expect(container.querySelector(".sl-legacy-card")).toHaveAttribute("aria-labelledby", "sl-handoff-failed-title");
    expect(document.title).toBe(`${turkish[reason].replace(/\.$/, "")} · SKY LAB`);
    expect(document.documentElement.lang).toBe("tr");
  });

  it("offers no form, no login link and no language switch, only the skip link and the KVKK notice", async () => {
    for (const reason of handoffFailureReasons) {
      const { container, unmount } = await renderFailure(reason);

      expect(container.querySelector("form, input, button")).toBeNull();
      expect(container.querySelector("nav.sl-legacy-languages")).toBeNull();
      const links = [...container.querySelectorAll("a")].map(link => link.getAttribute("href"));
      expect(links).toEqual(["#sl-handoff-failed-main", "https://skyl.app/kvkk-metni"]);
      expect(container.querySelector('[data-skylab-logo-animation="draw"]')).not.toBeNull();
      expect(container.querySelector("footer.sl-legacy-footer")).toHaveAttribute("role", "contentinfo");
      unmount();
    }
  });

  it("shows the generic sentence for a missing or unknown reason and never echoes it", async () => {
    const missing = await renderFailure(undefined);
    expect(missing.container.querySelector("h1")?.textContent).toBe(turkish.unavailable);
    missing.unmount();

    const hostile = await renderFailure("<img src=x onerror=alert(1)>");
    expect(hostile.container.querySelector("h1")?.textContent).toBe(turkish.unavailable);
    expect(hostile.container.innerHTML).not.toContain("onerror");
  });

  it("speaks the person's language when the realm resolved English", async () => {
    const { container } = await renderFailure("expired", "en");

    expect(container.querySelector("h1")?.textContent).toBe("This link has expired.");
    expect(container.querySelector(".sl-legacy-intro p")?.textContent).toBe("Go back to the app and try again.");
    expect(document.documentElement.lang).toBe("en");
  });
});
