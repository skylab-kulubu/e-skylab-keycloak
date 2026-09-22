package com.skylab.mail;

import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.events.Event;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.OrganizationModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;

import java.util.List;
import java.util.Map;

/**
 * Names the mail Keycloak is about to send.
 *
 * <p>{@code EmailSenderProvider} receives a rendered subject and body, not a template id, so by
 * the time the sender runs the identity of the mail is gone. This decorator sits in front of the
 * realm's stock freemarker template provider, records the SkyMail template key and the mail's
 * variables on the {@link KeycloakSession} that both providers share, and then delegates the
 * rendering unchanged. {@link SkyMailEmailSenderProvider} takes the recorded message off the
 * session — and the stock rendering is still produced, so the SMTP fallback has a body to send.</p>
 *
 * <p>The handoff is a session attribute rather than a thread local: the session is the exact
 * scope of one mail, it is discarded with the request, and a unit test can assert on it without
 * a running server.</p>
 */
public final class SkyMailEmailTemplateProvider implements EmailTemplateProvider {

    private final KeycloakSession session;
    private final EmailTemplateProvider delegate;

    private RealmModel realm;
    private UserModel user;

    SkyMailEmailTemplateProvider(KeycloakSession session, EmailTemplateProvider delegate) {
        this.session = session;
        this.delegate = delegate;
    }

    // --- capture -------------------------------------------------------------------------

    private void record(String templateKey, String subjectKey, String link, String expirationMinutes) {
        record(SkyMailMessage.of(templateKey, subjectKey, link, expirationMinutes, user, realm));
    }

    private void record(SkyMailMessage message) {
        session.setAttribute(SkyMailMessage.SESSION_ATTRIBUTE, message);
    }

    private void clear() {
        session.removeAttribute(SkyMailMessage.SESSION_ATTRIBUTE);
    }

    // --- EmailTemplateProvider ------------------------------------------------------------

    @Override
    public EmailTemplateProvider setAuthenticationSession(AuthenticationSessionModel authenticationSession) {
        delegate.setAuthenticationSession(authenticationSession);
        return this;
    }

    @Override
    public EmailTemplateProvider setRealm(RealmModel realm) {
        this.realm = realm;
        delegate.setRealm(realm);
        return this;
    }

    @Override
    public EmailTemplateProvider setUser(UserModel user) {
        this.user = user;
        delegate.setUser(user);
        return this;
    }

    @Override
    public EmailTemplateProvider setAttribute(String name, Object value) {
        delegate.setAttribute(name, value);
        return this;
    }

    @Override
    public void sendEvent(Event event) throws EmailException {
        record(SkyMailTemplates.GENERIC, SkyMailTemplates.eventSubjectKey(event.getType()), "", "");
        delegate.sendEvent(event);
    }

    @Override
    public void sendPasswordReset(String link, long expirationInMinutes) throws EmailException {
        record(SkyMailTemplates.RESET_PASSWORD, SkyMailTemplates.RESET_PASSWORD_SUBJECT_KEY,
                link, SkyMailMessage.minutes(expirationInMinutes));
        delegate.sendPasswordReset(link, expirationInMinutes);
    }

    /**
     * The SMTP test mail exists to prove the realm's own SMTP settings, so it never goes through
     * SkyMail. Clearing first also stops a message recorded earlier in this session from being
     * picked up by the test mail.
     */
    @Override
    public void sendSmtpTestEmail(Map<String, String> config, UserModel user) throws EmailException {
        clear();
        delegate.sendSmtpTestEmail(config, user);
    }

    @Override
    public void sendConfirmIdentityBrokerLink(String link, long expirationInMinutes) throws EmailException {
        record(SkyMailTemplates.IDP_LINK, SkyMailTemplates.IDP_LINK_SUBJECT_KEY,
                link, SkyMailMessage.minutes(expirationInMinutes));
        delegate.sendConfirmIdentityBrokerLink(link, expirationInMinutes);
    }

    @Override
    public void sendExecuteActions(String link, long expirationInMinutes) throws EmailException {
        record(SkyMailTemplates.GENERIC, SkyMailTemplates.EXECUTE_ACTIONS_SUBJECT_KEY,
                link, SkyMailMessage.minutes(expirationInMinutes));
        delegate.sendExecuteActions(link, expirationInMinutes);
    }

    @Override
    public void sendVerifiableCredentialOffer(String link, long expirationInMinutes) throws EmailException {
        record(SkyMailTemplates.GENERIC, "verifiableCredentialOfferSubject",
                link, SkyMailMessage.minutes(expirationInMinutes));
        delegate.sendVerifiableCredentialOffer(link, expirationInMinutes);
    }

    @Override
    public void sendVerifyEmail(String link, long expirationInMinutes) throws EmailException {
        record(SkyMailTemplates.VERIFY_EMAIL, SkyMailTemplates.VERIFY_EMAIL_SUBJECT_KEY,
                link, SkyMailMessage.minutes(expirationInMinutes));
        delegate.sendVerifyEmail(link, expirationInMinutes);
    }

    @Override
    public void sendOrgInviteEmail(OrganizationModel organization, String link, long expirationInMinutes)
            throws EmailException {
        record(SkyMailTemplates.GENERIC, "orgInviteSubject", link, SkyMailMessage.minutes(expirationInMinutes));
        delegate.sendOrgInviteEmail(organization, link, expirationInMinutes);
    }

    @Override
    public void sendEmailUpdateConfirmation(String link, long expirationInMinutes, String address)
            throws EmailException {
        record(SkyMailTemplates.UPDATE_EMAIL, SkyMailTemplates.UPDATE_EMAIL_SUBJECT_KEY,
                link, SkyMailMessage.minutes(expirationInMinutes));
        delegate.sendEmailUpdateConfirmation(link, expirationInMinutes, address);
    }

    @Override
    public void send(String subjectFormatKey, String bodyTemplate, Map<String, Object> bodyAttributes)
            throws EmailException {
        recordGeneric(subjectFormatKey, bodyTemplate, bodyAttributes);
        delegate.send(subjectFormatKey, bodyTemplate, bodyAttributes);
    }

    @Override
    public void send(String subjectFormatKey, List<Object> subjectAttributes, String bodyTemplate,
            Map<String, Object> bodyAttributes) throws EmailException {
        recordGeneric(subjectFormatKey, bodyTemplate, bodyAttributes);
        delegate.send(subjectFormatKey, subjectAttributes, bodyTemplate, bodyAttributes);
    }

    @Override
    public void send(String subjectFormatKey, String bodyTemplate, Map<String, Object> bodyAttributes,
            String destinationEmail) throws EmailException {
        recordGeneric(subjectFormatKey, bodyTemplate, bodyAttributes);
        delegate.send(subjectFormatKey, bodyTemplate, bodyAttributes, destinationEmail);
    }

    @Override
    public void send(String subjectFormatKey, List<Object> subjectAttributes, String bodyTemplate,
            Map<String, Object> bodyAttributes, String destinationEmail) throws EmailException {
        recordGeneric(subjectFormatKey, bodyTemplate, bodyAttributes);
        delegate.send(subjectFormatKey, subjectAttributes, bodyTemplate, bodyAttributes, destinationEmail);
    }

    /**
     * A mail sent through the generic overloads is named by its freemarker body template. The
     * Account Center personal e-mail code (K3c) arrives this way, carrying {@code code} and
     * {@code codeExpiration} instead of a link.
     */
    private void recordGeneric(String subjectFormatKey, String bodyTemplate,
            Map<String, Object> bodyAttributes) {
        Map<String, Object> attributes = bodyAttributes == null ? Map.of() : bodyAttributes;
        Object link = attributes.get(SkyMailMessage.LINK);
        Object code = attributes.get(SkyMailMessage.CODE);
        record(SkyMailMessage.of(SkyMailTemplates.forBodyTemplate(bodyTemplate),
                subjectFormatKey,
                link instanceof String text ? text : "",
                SkyMailMessage.minutes(attributes.get("linkExpiration")),
                code instanceof String text ? text : "",
                SkyMailMessage.minutes(attributes.get("codeExpiration")),
                user,
                realm));
    }

    @Override
    public void close() {
        delegate.close();
    }
}
