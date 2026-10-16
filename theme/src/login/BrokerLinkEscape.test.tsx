import { cleanup, render, waitFor } from "@testing-library/react";
import { afterEach, beforeAll, expect, it } from "vitest";
import { getDevKcContextForPage } from "../devKcContext";
import KcPage from "./KcPage";

beforeAll(() => window.history.replaceState(null, "", "/?viewMode=docs"));
afterEach(cleanup);

it.each(["login.ftl", "login-otp.ftl"] as const)("%s has a separate broker escape POST", async pageId => {
  const kcContext = getDevKcContextForPage(pageId);
  kcContext.skyExistingAccountEscape = true;
  const { container } = render(<KcPage kcContext={kcContext} />);
  await waitFor(() => expect(container.querySelector('[name="sky-existing-account-action"]')).not.toBeNull());
  const escape = container.querySelector<HTMLButtonElement>('[name="sky-existing-account-action"]')!;
  expect(escape).toHaveAttribute("value", "new-account");
  expect(escape.form).toHaveAttribute("method", "post");
  expect(escape.form).toHaveAttribute("action", kcContext.url.loginAction);
  expect(container.querySelector("form form")).toBeNull();
  if (pageId === "login.ftl") {
    expect(container.querySelector("#kc-form-login")).not.toBeNull();
    expect(container.querySelector(".sl-legacy-back, .sl-legacy-forgot, .sl-legacy-no-account, #rememberMe")).toBeNull();
  }
});
