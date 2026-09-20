import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import LegacyFrame from "./LegacyFrame";

describe("LegacyFrame SKY LAB identity", () => {
  it("renders the Forms-style vector drawing instead of a static logo image", () => {
    const { container } = render(
      <LegacyFrame
        description="Açıklama"
        kvkkLinkText="KVKK metnini"
        kvkkPrefix="Devam ederek "
        kvkkSuffix=" kabul edersiniz."
        mainId="main"
        skipToContent="İçeriğe geç"
        title="Giriş yap"
        titleId="title"
      >
        <p>İçerik</p>
      </LegacyFrame>
    );

    const animation = container.querySelector('[data-skylab-logo-animation="draw"]');

    expect(animation).not.toBeNull();
    expect(animation).toHaveAttribute("role", "img");
    expect(animation).toHaveAttribute("aria-label", "SKY LAB");
    expect(animation?.querySelectorAll("path")).toHaveLength(19);
    expect(animation?.querySelector("path")).toHaveAttribute("pathLength", "1");
    expect(container.querySelector(".sl-legacy-logo img")).toBeNull();
  });
});
