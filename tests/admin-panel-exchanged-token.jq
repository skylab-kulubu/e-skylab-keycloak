# The contract of a token that Standard Token Exchange gives the admin panel's server for ONE API
# (ADR-0058; admin-token-authz K1). Input: the payload of the exchanged access token. Arguments:
# $aud (core, forms or skycms) and $subject (the payload of the panel's own access token, the
# subject_token of the exchange). Output: the list of violations; empty when the token keeps the
# contract. Messages name claims, never values (no token or personal data in CI logs).
#
# The exchange may only narrow: the token is the panel's token with aud cut to the one API and
# resource_access cut to that API's roles. Every other claim of the panel's token stays with the
# same value (sub, azp, sid, groups, the flat roles, the profile, scope, acr, ...), none is added,
# and the token lives no longer than the panel's own.
#
# What each API reads from the token (origin/main, 2026-10-05):
#   core    core-backend a6cec45 internal/authn/jwt.go: iss, aud contains core, sub (UUID), azp,
#           email, given_name, family_name, preferred_username, school_email, sky_number,
#           university, department (when the realm writes them), groups (full paths; or the
#           Group overage marker _claim_names.groups), resource_access.core.roles; client_id equal
#           to azp marks a service account, so a person's token must not carry it.
#   forms   forms-backend b72ef63 src/Forms.Api/Auth/FormsJwtAuthenticationExtensions.cs,
#           src/Forms.Infrastructure/Auth/JwtCurrentUserService.cs: iss, aud contains forms, sub
#           (GUID), resource_access.forms.roles (skyforms:*).
#   skycms  inscribed-dotnet 2ecc548 (v2.0.1; Audience skycms, TenantClaim azp, RolesClaim roles):
#           aud contains skycms, azp (the tenant), sub, the flat roles (content:*), groups (full
#           paths, collection rules), email (the client and service admin routes).
def as_list: if . == null then [] elif type == "array" then . else [.] end;
# Claims the API reads that every person's token must carry. groups and the flat roles are kept by
# the equality below whenever the panel's token has them; a person without groups or panel roles
# has neither, and the APIs then refuse what needs them.
def needed:
  {
    core: ["iss", "sub", "azp", "email", "given_name", "family_name", "preferred_username"],
    forms: ["iss", "sub"],
    skycms: ["iss", "sub", "azp", "email"]
  }[$aud] // error("unknown audience \($aud)");
# Claims that differ between the two tokens by construction.
def per_token: ["aud", "resource_access", "exp", "iat", "jti"];
. as $token
| ($subject.resource_access // {} | with_entries(select(.key == $aud))) as $resource_access
| [
    (if ($token.aud | as_list) != [$aud] then "aud is not exactly \($aud)" else empty end),
    (if ($token.resource_access // {}) != $resource_access
      then "resource_access is not exactly the \($aud) roles of the panel token (it has \($token.resource_access // {} | keys | tojson))"
      else empty end),
    (if $token | has("realm_access") then "realm_access is present" else empty end),
    (if $token | has("client_id") then "client_id is present (core would take the person for a service account)" else empty end),
    ((($token | keys) - ($subject | keys))[] | "claim \(.) is not in the panel token"),
    (($subject | keys)[] as $claim
      | select(per_token | index($claim) | not)
      | select(($token | has($claim) | not) or $token[$claim] != $subject[$claim])
      | "claim \($claim) is not the panel token's"),
    (needed[] as $claim | select(($token[$claim] // "") == "") | "claim \($claim), which \($aud) reads, is missing"),
    (if $token.typ != "Bearer" then "typ is not Bearer" else empty end),
    (if ($token.exp | type) != "number" or ($token.iat | type) != "number" or $token.exp <= $token.iat
      then "exp is not after iat"
      elif ($token.exp - $token.iat) > ($subject.exp - $subject.iat)
      then "the token lives longer than the panel token"
      else empty end)
  ]
