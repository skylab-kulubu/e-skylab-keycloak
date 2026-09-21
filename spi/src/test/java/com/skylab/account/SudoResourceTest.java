package com.skylab.account;

import org.junit.jupiter.api.Test;
import org.keycloak.events.EventBuilder;
import org.keycloak.events.EventType;
import org.mockito.InOrder;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

class SudoResourceTest {

    @Test
    void auditsEverySuccessfulSudoAsACustomRequiredActionEvent() {
        for (SudoTokens.Method method : SudoTokens.Method.values()) {
            EventBuilder event = mock(EventBuilder.class, RETURNS_SELF);

            SudoResource.recordSudoSuccess(event, method);

            InOrder inOrder = inOrder(event);
            inOrder.verify(event).event(EventType.CUSTOM_REQUIRED_ACTION);
            inOrder.verify(event).detail("action", "sky-sudo");
            inOrder.verify(event).detail("method", method == SudoTokens.Method.PASSWORD ? "password" : "totp");
            inOrder.verify(event).success();
            verify(event, never()).error(anyString());
        }
    }
}
