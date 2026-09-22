package com.skylab.mail;

import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.events.Event;
import org.keycloak.models.OrganizationModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Stands in for Keycloak's freemarker template provider: records the calls the {@code sky-mail}
 * decorator passes through, so a test can prove the rendering is still asked for unchanged.
 */
final class FakeEmailTemplateProvider implements EmailTemplateProvider {

    final List<String> calls = new ArrayList<>();
    RealmModel realm;
    UserModel user;
    boolean closed;

    @Override
    public EmailTemplateProvider setAuthenticationSession(AuthenticationSessionModel authenticationSession) {
        calls.add("setAuthenticationSession");
        return this;
    }

    @Override
    public EmailTemplateProvider setRealm(RealmModel realm) {
        this.realm = realm;
        calls.add("setRealm");
        return this;
    }

    @Override
    public EmailTemplateProvider setUser(UserModel user) {
        this.user = user;
        calls.add("setUser");
        return this;
    }

    @Override
    public EmailTemplateProvider setAttribute(String name, Object value) {
        calls.add("setAttribute:" + name);
        return this;
    }

    @Override
    public void sendEvent(Event event) {
        calls.add("sendEvent:" + event.getType());
    }

    @Override
    public void sendPasswordReset(String link, long expirationInMinutes) {
        calls.add("sendPasswordReset:" + link + ":" + expirationInMinutes);
    }

    @Override
    public void sendSmtpTestEmail(Map<String, String> config, UserModel user) {
        calls.add("sendSmtpTestEmail");
    }

    @Override
    public void sendConfirmIdentityBrokerLink(String link, long expirationInMinutes) {
        calls.add("sendConfirmIdentityBrokerLink:" + link + ":" + expirationInMinutes);
    }

    @Override
    public void sendExecuteActions(String link, long expirationInMinutes) {
        calls.add("sendExecuteActions:" + link + ":" + expirationInMinutes);
    }

    @Override
    public void sendVerifiableCredentialOffer(String link, long expirationInMinutes) {
        calls.add("sendVerifiableCredentialOffer:" + link + ":" + expirationInMinutes);
    }

    @Override
    public void sendVerifyEmail(String link, long expirationInMinutes) {
        calls.add("sendVerifyEmail:" + link + ":" + expirationInMinutes);
    }

    @Override
    public void sendOrgInviteEmail(OrganizationModel organization, String link, long expirationInMinutes) {
        calls.add("sendOrgInviteEmail:" + link + ":" + expirationInMinutes);
    }

    @Override
    public void sendEmailUpdateConfirmation(String link, long expirationInMinutes, String address) {
        calls.add("sendEmailUpdateConfirmation:" + link + ":" + expirationInMinutes + ":" + address);
    }

    @Override
    public void send(String subjectFormatKey, String bodyTemplate, Map<String, Object> bodyAttributes) {
        calls.add("send3:" + subjectFormatKey + ":" + bodyTemplate);
    }

    @Override
    public void send(String subjectFormatKey, List<Object> subjectAttributes, String bodyTemplate,
            Map<String, Object> bodyAttributes) {
        calls.add("send4:" + subjectFormatKey + ":" + bodyTemplate);
    }

    @Override
    public void send(String subjectFormatKey, String bodyTemplate, Map<String, Object> bodyAttributes,
            String destinationEmail) {
        calls.add("send4a:" + subjectFormatKey + ":" + bodyTemplate + ":" + destinationEmail);
    }

    @Override
    public void send(String subjectFormatKey, List<Object> subjectAttributes, String bodyTemplate,
            Map<String, Object> bodyAttributes, String destinationEmail) {
        calls.add("send5:" + subjectFormatKey + ":" + bodyTemplate + ":" + destinationEmail);
    }

    @Override
    public void close() {
        closed = true;
    }
}
