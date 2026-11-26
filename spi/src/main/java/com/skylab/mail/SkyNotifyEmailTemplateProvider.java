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
 * realm's stock freemarker template provider, records the SkyNotify template key and the mail's
 * variables on the {@link KeycloakSession} that both providers share, and then delegates the
 * rendering unchanged. {@link SkyNotifyEmailSenderProvider} takes the recorded message off the
 * session — and the stock rendering is still produced, so the SMTP fallback has a body to send.</p>
 *
 * <p>The handoff is a session attribute rather than a thread local: the session is the exact
 * scope of one mail, it is discarded with the request, and a unit test can assert on it without
 * a running server.</p>
 */
public final class SkyNotifyEmailTemplateProvider implements EmailTemplateProvider {

    private final KeycloakSession session;
    private final EmailTemplateProvider delegate;

    private RealmModel realm;
    private UserModel user;

    SkyNotifyEmailTemplateProvider(KeycloakSession session, EmailTemplateProvider delegate) {
        this.session = session;
        this.delegate = delegate;
    }

    // --- capture -------------------------------------------------------------------------

    private void record(String templateKey, String subjectKey, String link, String expirationMinutes) {
        record(SkyNotifyMessage.of(templateKey, subjectKey, link, expirationMinutes, user, realm));
    }

    private void record(SkyNotifyMessage message) {
        session.setAttribute(SkyNotifyMessage.SESSION_ATTRIBUTE, message);
    }

    private void clear() {
        session.removeAttribute(SkyNotifyMessage.SESSION_ATTRIBUTE);
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
        record(SkyNotifyTemplates.GENERIC, SkyNotifyTemplates.eventSubjectKey(event.getType()), "", "");
        delegate.sendEvent(event);
    }

    @Override
    public void sendPasswordReset(String link, long expirationInMinutes) throws EmailException {
        record(SkyNotifyTemplates.RESET_PASSWORD, SkyNotifyTemplates.RESET_PASSWORD_SUBJECT_KEY,
                link, SkyNotifyMessage.minutes(expirationInMinutes));
        delegate.sendPasswordReset(link, expirationInMinutes);
    }

    /**
     * The SMTP test mail exists to prove the realm's own SMTP settings, so it never goes through
     * SkyNotify. Clearing first also stops a message recorded earlier in this session from being
     * picked up by the test mail.
     */
    @Override
    public void sendSmtpTestEmail(Map<String, String> config, UserModel user) throws EmailException {
        clear();
        delegate.sendSmtpTestEmail(config, user);
    }

    @Override
    public void sendConfirmIdentityBrokerLink(String link, long expirationInMinutes) throws EmailException {
        record(SkyNotifyTemplates.IDP_LINK, SkyNotifyTemplates.IDP_LINK_SUBJECT_KEY,
                link, SkyNotifyMessage.minutes(expirationInMinutes));
        delegate.sendConfirmIdentityBrokerLink(link, expirationInMinutes);
    }

    @Override
    public void sendExecuteActions(String link, long expirationInMinutes) throws EmailException {
        record(SkyNotifyTemplates.GENERIC, SkyNotifyTemplates.EXECUTE_ACTIONS_SUBJECT_KEY,
                link, SkyNotifyMessage.minutes(expirationInMinutes));
        delegate.sendExecuteActions(link, expirationInMinutes);
    }

    @Override
    public void sendVerifiableCredentialOffer(String link, long expirationInMinutes) throws EmailException {
        record(SkyNotifyTemplates.GENERIC, "verifiableCredentialOfferSubject",
                link, SkyNotifyMessage.minutes(expirationInMinutes));
        delegate.sendVerifiableCredentialOffer(link, expirationInMinutes);
    }

    @Override
    public void sendVerifyEmail(String link, long expirationInMinutes) throws EmailException {
        record(SkyNotifyTemplates.VERIFY_EMAIL, SkyNotifyTemplates.VERIFY_EMAIL_SUBJECT_KEY,
                link, SkyNotifyMessage.minutes(expirationInMinutes));
        delegate.sendVerifyEmail(link, expirationInMinutes);
    }

    @Override
    public void sendOrgInviteEmail(OrganizationModel organization, String link, long expirationInMinutes)
            throws EmailException {
        record(SkyNotifyTemplates.GENERIC, "orgInviteSubject", link, SkyNotifyMessage.minutes(expirationInMinutes));
        delegate.sendOrgInviteEmail(organization, link, expirationInMinutes);
    }

    @Override
    public void sendEmailUpdateConfirmation(String link, long expirationInMinutes, String address)
            throws EmailException {
        record(SkyNotifyTemplates.UPDATE_EMAIL, SkyNotifyTemplates.UPDATE_EMAIL_SUBJECT_KEY,
                link, SkyNotifyMessage.minutes(expirationInMinutes));
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
     * {@code codeExpiration} instead of a link, and so does the Login code, which also carries
     * {@code purpose}.
     */
    private void recordGeneric(String subjectFormatKey, String bodyTemplate,
            Map<String, Object> bodyAttributes) {
        Map<String, Object> attributes = bodyAttributes == null ? Map.of() : bodyAttributes;
        Object link = attributes.get(SkyNotifyMessage.LINK);
        Object code = attributes.get(SkyNotifyMessage.CODE);
        Object purpose = attributes.get(SkyNotifyMessage.PURPOSE);
        record(SkyNotifyMessage.of(SkyNotifyTemplates.forBodyTemplate(bodyTemplate),
                subjectFormatKey,
                link instanceof String text ? text : "",
                SkyNotifyMessage.minutes(attributes.get("linkExpiration")),
                code instanceof String text ? text : "",
                SkyNotifyMessage.minutes(attributes.get("codeExpiration")),
                purpose instanceof String text ? text : "",
                user,
                realm));
    }

    @Override
    public void close() {
        delegate.close();
    }
}
