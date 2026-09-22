package com.skylab.handoff;

import java.util.HashMap;
import java.util.Map;

/**
 * What one handoff code grants, kept server-side next to the hash of the code and never sent
 * anywhere: who, from which source session, with which original authentication time, to which
 * target and path, and the address the code was minted from.
 *
 * @param realmId         the realm the code was minted in
 * @param userId          the person the browser session is created for
 * @param sourceSessionId the SkyApp user session behind the bearer token
 * @param sourceOffline   whether that session is an offline session (SkyApp signs in with
 *                        {@code offline_access}); an online session may share its id
 * @param authTime        the source session's original {@code auth_time} (epoch seconds)
 * @param clientId        the Handoff target's {@code client_id}
 * @param path            the relative path the person lands on
 * @param ipAddress       the address the code was minted from, or {@code null} when unknown
 */
record HandoffGrant(
        String realmId,
        String userId,
        String sourceSessionId,
        boolean sourceOffline,
        long authTime,
        String clientId,
        String path,
        String ipAddress) {

    private static final String REALM_ID = "realmId";
    private static final String USER_ID = "userId";
    private static final String SOURCE_SESSION_ID = "sourceSessionId";
    private static final String SOURCE_OFFLINE = "sourceOffline";
    private static final String AUTH_TIME = "authTime";
    private static final String CLIENT_ID = "clientId";
    private static final String PATH = "path";
    private static final String IP_ADDRESS = "ipAddress";

    /** The grant as single-use store notes (the store refuses {@code null} values). */
    Map<String, String> toNotes() {
        Map<String, String> notes = new HashMap<>();
        notes.put(REALM_ID, realmId);
        notes.put(USER_ID, userId);
        notes.put(SOURCE_SESSION_ID, sourceSessionId);
        notes.put(SOURCE_OFFLINE, Boolean.toString(sourceOffline));
        notes.put(AUTH_TIME, Long.toString(authTime));
        notes.put(CLIENT_ID, clientId);
        notes.put(PATH, path);
        if (ipAddress != null) {
            notes.put(IP_ADDRESS, ipAddress);
        }
        return notes;
    }

    /** @return the grant the notes describe, or {@code null} when they are incomplete or malformed */
    static HandoffGrant fromNotes(Map<String, String> notes) {
        try {
            HandoffGrant grant = new HandoffGrant(
                    notes.get(REALM_ID),
                    notes.get(USER_ID),
                    notes.get(SOURCE_SESSION_ID),
                    Boolean.parseBoolean(notes.get(SOURCE_OFFLINE)),
                    Long.parseLong(notes.get(AUTH_TIME)),
                    notes.get(CLIENT_ID),
                    notes.get(PATH),
                    notes.get(IP_ADDRESS));
            boolean complete = grant.realmId() != null && grant.userId() != null && grant.sourceSessionId() != null
                    && grant.clientId() != null && grant.path() != null;
            return complete ? grant : null;
        } catch (RuntimeException exception) {
            return null;
        }
    }
}
