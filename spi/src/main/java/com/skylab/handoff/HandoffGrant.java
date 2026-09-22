package com.skylab.handoff;

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
}
