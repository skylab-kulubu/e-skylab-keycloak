# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert and v2_jwt_payload.
#
# Group overage (ADR-0059, admin-token-authz ticket 12): the SPI's sky-group-overage-mapper in the
# built image, in a throwaway realm imported in one call. A person in 30 group paths gets the
# groups claim as Keycloak's Group Membership mapper writes it, in the access token, the ID token
# and userinfo; a person in 31 gets no groups claim there and Microsoft's marker instead
# (_claim_names.groups, which core-backend detects). A person without groups gets neither. The
# admin API refuses a threshold that is not a whole number. No production client uses the mapper.

GO_REALM=group-overage-test
GO_CLIENT=group-overage-fixture
GO_SECRET=group-overage-fixture-secret-change-me
GO_PASSWORD=group-overage-fixture-password-change-me

# The realm: /OVERAGE/G01…G31, users go0 (no group), go30 (G01…G30), go31 (G01…G31), and a
# confidential direct-grant client whose only groups mapper is the overage mapper (threshold 30).
go_realm_json() {
  jq -n -c --arg realm "$GO_REALM" --arg client "$GO_CLIENT" --arg secret "$GO_SECRET" \
    --arg password "$GO_PASSWORD" '
    def paths(n): [range(1; n + 1) | "/OVERAGE/G\(if . < 10 then "0" else "" end)\(.)"];
    def person(name; n): {
      username: name, enabled: true, email: "\(name)@example.test", emailVerified: true,
      firstName: "Group", lastName: "Overage",
      credentials: [{type: "password", value: $password, temporary: false}],
      groups: paths(n)
    };
    {
      realm: $realm, enabled: true,
      groups: [{name: "OVERAGE", subGroups: [paths(31)[] | {name: (split("/") | last)}]}],
      users: [person("go0"; 0), person("go30"; 30), person("go31"; 31)],
      clients: [{
        clientId: $client, enabled: true, publicClient: false, secret: $secret,
        standardFlowEnabled: false, directAccessGrantsEnabled: true,
        protocolMappers: [{
          name: "groups", protocol: "openid-connect", protocolMapper: "sky-group-overage-mapper",
          config: {
            "claim.name": "groups", "full.path": "true", "overage.threshold": "30",
            "id.token.claim": "true", "access.token.claim": "true",
            "userinfo.token.claim": "true", "introspection.token.claim": "true"
          }
        }]
      }]
    }'
}

GO_ACCESS=''
GO_ID=''
GO_USERINFO=''
# go_login USER: a password grant through the fixture client; leaves the access token payload, the
# ID token payload and the userinfo response in GO_ACCESS, GO_ID and GO_USERINFO.
go_login() {
  local response access_token
  response=$(curl --fail --silent --show-error \
    --user "$GO_CLIENT:$GO_SECRET" \
    --data-urlencode grant_type=password \
    --data-urlencode "username=$1" \
    --data-urlencode "password=$GO_PASSWORD" \
    --data-urlencode scope=openid \
    "http://localhost:18080/realms/$GO_REALM/protocol/openid-connect/token") \
    || fail "the password grant of $1 failed"
  access_token=$(jq -r .access_token <<<"$response")
  GO_ACCESS=$(v2_jwt_payload "$access_token")
  GO_ID=$(v2_jwt_payload "$(jq -r .id_token <<<"$response")")
  GO_USERINFO=$(curl --fail --silent --show-error -H "Authorization: Bearer $access_token" \
    "http://localhost:18080/realms/$GO_REALM/protocol/openid-connect/userinfo") \
    || fail "userinfo of $1 failed"
}

stage_group_overage_mapper() {
  CURRENT_STAGE='group overage mapper (SPI) in a throwaway realm'
  local surface payload expected user_id client_uuid status
  go_realm_json | kcadm create realms -f - >/dev/null
  expected=$(jq -n -c '[range(1; 31) | "/OVERAGE/G\(if . < 10 then "0" else "" end)\(.)"]')

  go_login go30
  for surface in access id userinfo; do
    case $surface in
      access) payload=$GO_ACCESS ;;
      id) payload=$GO_ID ;;
      userinfo) payload=$GO_USERINFO ;;
    esac
    json_assert "$payload" '(.groups | sort) == $want and (has("_claim_names") | not) and (has("_claim_sources") | not)' \
      "the $surface of a person in 30 groups does not carry exactly the 30 full paths" --argjson want "$expected"
  done

  go_login go31
  user_id=$(jq -r .sub <<<"$GO_ACCESS")
  for surface in access id userinfo; do
    case $surface in
      access) payload=$GO_ACCESS ;;
      id) payload=$GO_ID ;;
      userinfo) payload=$GO_USERINFO ;;
    esac
    json_assert "$payload" \
      '(has("groups") | not) and ._claim_names == {"groups": "src1"} and (._claim_sources | keys) == ["src1"]
        and (._claim_sources.src1 | keys) == ["endpoint"] and (._claim_sources.src1.endpoint | test("^https?://") and endswith($path))' \
      "the $surface of a person in 31 groups does not carry the Group overage marker instead of the list" \
      --arg path "/admin/realms/$GO_REALM/users/$user_id/groups"
  done

  go_login go0
  for payload in "$GO_ACCESS" "$GO_ID" "$GO_USERINFO"; do
    json_assert "$payload" '(has("groups") | not) and (has("_claim_names") | not)' \
      'a person without groups got a groups claim or the marker'
  done

  # The admin API refuses a threshold that is not a whole number (validateConfig).
  client_uuid=$(kcadm get clients -r "$GO_REALM" -q "clientId=$GO_CLIENT" -c | jq -r '.[0].id')
  if kcadm create "clients/$client_uuid/protocol-mappers/models" -r "$GO_REALM" \
    -b '{"name":"bad-threshold","protocol":"openid-connect","protocolMapper":"sky-group-overage-mapper","config":{"overage.threshold":"many"}}' \
    >/dev/null 2>&1; then
    status=accepted
  else
    status=refused
  fi
  [[ $status == refused ]] || fail 'the admin API accepted a group overage threshold that is not a whole number'

  kcadm delete "realms/$GO_REALM" >/dev/null
}
