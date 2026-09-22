package com.skylab.account;

import org.keycloak.models.ClientModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;

/** The authenticated Account Center person behind a request: user, live session, bearer token. */
record Caller(UserModel user, UserSessionModel userSession, AccessToken token, ClientModel client) {
}
