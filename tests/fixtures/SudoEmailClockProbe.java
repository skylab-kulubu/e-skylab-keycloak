package com.skylab.account;

import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.NotFoundException;
import org.keycloak.Config;
import org.keycloak.common.util.Time;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;
import java.util.Map;

/** Test-only clock control, compiled into a separate local harness jar; never the production SPI. */
public final class SudoEmailClockProbe implements RealmResourceProviderFactory {
    public String getId() { return "sudo-email-clock"; }
    public void init(Config.Scope config) { }
    public void postInit(KeycloakSessionFactory factory) { }
    public void close() { }
    public RealmResourceProvider create(KeycloakSession session) {
        return new RealmResourceProvider() {
            public Object getResource() {
                if (!"1".equals(System.getenv("SKY_HARNESS"))
                        || !session.getContext().getRealm().getName().startsWith("sudo-email-test-")) {
                    throw new NotFoundException();
                }
                return new ClockResource();
            }
            public void close() { }
        };
    }
    public static final class ClockResource {
        @POST @Path("{seconds}")
        public Map<String, Integer> offset(@PathParam("seconds") int seconds) {
            if (seconds != 0 && seconds != 601) throw new NotFoundException();
            Time.setOffset(seconds);
            return Map.of("offset", seconds);
        }
    }
}
