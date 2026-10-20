#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
MISSING_IMAGE="account-keycloak-definitely-missing-$RANDOM-$$"
INTEGRATION_COMPOSE="$SCRIPT_DIR/docker-compose.integration.yml"

fail() {
  printf 'fresh-runner validation failure: %s\n' "$1" >&2
  exit 1
}

if docker image inspect "$MISSING_IMAGE" >/dev/null 2>&1; then
  fail "fixture image unexpectedly exists: $MISSING_IMAGE"
fi

# CI's stock runner contract is bash plus standard Unix tools. Keep local-only
# conveniences such as ripgrep out of every executable verification script.
for verification_script in "$SCRIPT_DIR"/*.sh; do
  [[ $verification_script == "$SCRIPT_DIR/check-fresh-runner.sh" ]] && continue
  if grep -Eq '(^|[[:space:];|&()])rg([[:space:]]|$)' "$verification_script"; then
    fail "verification script has an undeclared ripgrep dependency: $verification_script"
  fi
done

# This check is intentionally executed with a missing candidate. Static/render
# validation must complete before any workflow build step on a fresh runner.
KEYCLOAK_TEST_IMAGE="$MISSING_IMAGE" \
  "$SCRIPT_DIR/check-production-compose.sh" >/dev/null

# Runtime checks must never silently select a conventional local tag. The
# already-built candidate is an explicit input shared by all fixture services.
if env -u KEYCLOAK_TEST_IMAGE \
  docker compose -f "$INTEGRATION_COMPOSE" config --quiet >/dev/null 2>&1; then
  fail 'integration Compose accepted a missing KEYCLOAK_TEST_IMAGE'
fi
grep -Fq 'TEST_IMAGE=${KEYCLOAK_TEST_IMAGE:?' "$SCRIPT_DIR/run-integration.sh" \
  || fail 'integration runner does not require the exact candidate image'

release_gate="$SCRIPT_DIR/check-physical-webauthn-release.sh"
fake_commit=0123456789abcdef0123456789abcdef01234567
if GITHUB_SHA="$fake_commit" "$release_gate" >/dev/null 2>&1; then
  fail 'physical WebAuthn release gate accepted missing evidence'
fi
if GITHUB_SHA="$fake_commit" \
  PHYSICAL_WEBAUTHN_APPROVED_COMMIT=ffffffffffffffffffffffffffffffffffffffff \
  PHYSICAL_WEBAUTHN_EVIDENCE_URL=https://evidence.example.invalid/keycloak \
  PHYSICAL_WEBAUTHN_APPROVED_SURFACES=touch-id \
  "$release_gate" >/dev/null 2>&1; then
  fail 'physical WebAuthn release gate accepted evidence for another commit'
fi
if GITHUB_SHA="$fake_commit" \
  PHYSICAL_WEBAUTHN_APPROVED_COMMIT="$fake_commit" \
  PHYSICAL_WEBAUTHN_EVIDENCE_URL=https://evidence.example.invalid/keycloak \
  PHYSICAL_WEBAUTHN_APPROVED_SURFACES=touch-id,face-id \
  "$release_gate" >/dev/null 2>&1; then
  fail 'physical WebAuthn release gate accepted untested rollout surfaces'
fi
GITHUB_SHA="$fake_commit" \
  PHYSICAL_WEBAUTHN_APPROVED_COMMIT="$fake_commit" \
  PHYSICAL_WEBAUTHN_EVIDENCE_URL=https://evidence.example.invalid/keycloak \
  PHYSICAL_WEBAUTHN_APPROVED_SURFACES=touch-id \
  "$release_gate" >/dev/null

ruby -ryaml - "$REPOSITORY_ROOT" <<'RUBY'
root = ARGV.fetch(0)

def assert_order(workflow, job_name)
  document = YAML.load_file(workflow, aliases: true)
  job = document.fetch("jobs").fetch(job_name)
  steps = job.fetch("steps")
  static_index = steps.index do |step|
    step.fetch("run", "").include?("tests/check-fresh-runner.sh")
  end
  build_index = steps.index do |step|
    step["uses"] == "docker/build-push-action@v7"
  end
  integration_index = steps.index do |step|
    step.fetch("run", "").include?("tests/run-integration.sh")
  end
  unless static_index && build_index && integration_index &&
      static_index < build_index && build_index < integration_index
    abort "#{workflow} #{job_name} must run fresh-runner static checks, then build, then integration"
  end

  build = steps.fetch(build_index).fetch("with")
  abort "#{workflow} #{job_name} must load the tested candidate locally" unless build["load"] == true
  test_image = job.fetch("env").fetch("KEYCLOAK_TEST_IMAGE")
  if test_image.to_s.empty?
    abort "#{workflow} #{job_name} must name the candidate image explicitly"
  end
  unless build["tags"] == "${{ env.KEYCLOAK_TEST_IMAGE }}"
    abort "#{workflow} #{job_name} must build the exact KEYCLOAK_TEST_IMAGE used by integration"
  end
  if steps.fetch(integration_index).fetch("env", {}).key?("KEYCLOAK_TEST_IMAGE")
    abort "#{workflow} #{job_name} must not override the job's tested candidate in the integration step"
  end
end

# A step that checks the tarball's SHA-256 against keycloak-build's output (sha256sum --check
# --strict on "$IMAGE_SHA256") and the loaded image ID against it (= "$IMAGE_ID").
def binds_to_build_outputs?(run)
  lines = run.lines
  lines.any? { |line| line.include?('"$IMAGE_SHA256"') && line.include?("sha256sum --check --strict") } &&
    lines.any? { |line| line.include?("docker image inspect") && line.include?('= "$IMAGE_ID"') }
end

def assert_release_boundary(workflow)
  document = YAML.load_file(workflow, aliases: true)
  triggers = document[true] || document["on"]
  push = triggers.fetch("push")
  unless push.fetch("branches") == ["production"] && push.fetch("tags") == ["v*"]
    abort "#{workflow} must publish only from production and semantic version tags"
  end

  jobs = document.fetch("jobs")
  build_job = jobs.fetch("keycloak-build")
  package_job = jobs.fetch("keycloak-package")
  publish_job = jobs.fetch("keycloak-publish")
  build_steps = build_job.fetch("steps")
  package_steps = package_job.fetch("steps")
  publish_steps = publish_job.fetch("steps")

  jobs.each do |name, job|
    next if name == "keycloak-publish"
    if job.fetch("permissions", {}).fetch("packages", nil) == "write"
      abort "#{workflow} #{name} must not receive package-write permission"
    end
  end
  unless publish_job.fetch("permissions", {}).fetch("packages", nil) == "write"
    abort "#{workflow} keycloak-publish must own the package-write permission"
  end
  # Publishing and the Dokploy deployment run in the keycloak-production environment, whose
  # branch policy admits only production and v* tags; the hook is read nowhere else.
  unless publish_job.fetch("environment", nil) == "keycloak-production"
    abort "#{workflow} keycloak-publish must run in the keycloak-production environment"
  end
  jobs.each do |name, job|
    next if name == "keycloak-publish"
    if job.to_s.include?("DOKPLOY_DEPLOY_HOOK")
      abort "#{workflow} #{name} must not read the Dokploy deploy hook"
    end
  end
  unless Array(publish_job.fetch("needs", nil)).sort == ["keycloak-build", "keycloak-package"]
    abort "#{workflow} keycloak-publish must depend on the build and the tested and physically approved package job"
  end
  unless publish_job.fetch("env", {}).fetch("IMAGE_ID", nil) == "${{ needs.keycloak-build.outputs.image-id }}" &&
      publish_job.fetch("env", {}).fetch("IMAGE_SHA256", nil) == "${{ needs.keycloak-build.outputs.image-sha256 }}"
    abort "#{workflow} keycloak-publish must bind the candidate to keycloak-build's image ID and SHA-256"
  end
  concurrency = document.fetch("concurrency", nil)
  unless concurrency == { "group" => "keycloak-release", "cancel-in-progress" => false }
    abort "#{workflow} must run one release at a time without cancelling the one in progress"
  end

  # A failed test, gate or check must stop the release: no job or step of the release path may
  # carry on after a failure, and package and publish run only on success.
  ["keycloak-build", "keycloak-package", "keycloak-publish"].each do |name|
    job = jobs.fetch(name)
    if job.key?("continue-on-error") || job.fetch("steps").any? { |step| step.key?("continue-on-error") }
      abort "#{workflow} #{name} must not continue on error"
    end
    unless !job.key?("if") || job["if"].to_s.gsub(/\s|\$\{\{|\}\}/, "") == "success()"
      abort "#{workflow} #{name} may run only when every job it needs succeeded (if: #{job["if"]})"
    end
    job.fetch("steps").each do |step|
      if step.fetch("if", "").to_s =~ /always\(|cancelled\(|failure\(/
        abort "#{workflow} #{name} step #{step.fetch("name", step["uses"])} must not run after a failure"
      end
    end
  end
  unless jobs.keys.sort == ["keycloak-build", "keycloak-package", "keycloak-publish"]
    abort "#{workflow} must only promote, approve and publish CI's tested candidate (jobs #{jobs.keys.join(" ")})"
  end
  unless Array(package_job.fetch("needs", nil)) == ["keycloak-build"]
    abort "#{workflow} keycloak-package must run only when keycloak-build found and checked the tested candidate"
  end
  unless package_job.fetch("environment", nil) == "keycloak-production"
    abort "#{workflow} keycloak-package must read the physical WebAuthn evidence of the keycloak-production environment"
  end
  # The evidence comes only from the environment's variables: a value derived from the run (such
  # as github.sha) would approve itself.
  evidence = package_job.fetch("env", {}).select { |name, _| name.start_with?("PHYSICAL_WEBAUTHN_") }
  unless evidence == {
    "PHYSICAL_WEBAUTHN_APPROVED_COMMIT" => "${{ vars.KEYCLOAK_PHYSICAL_WEBAUTHN_APPROVED_COMMIT }}",
    "PHYSICAL_WEBAUTHN_EVIDENCE_URL" => "${{ vars.KEYCLOAK_PHYSICAL_WEBAUTHN_EVIDENCE_URL }}",
    "PHYSICAL_WEBAUTHN_APPROVED_SURFACES" => "${{ vars.KEYCLOAK_PHYSICAL_WEBAUTHN_APPROVED_SURFACES }}",
  }
    abort "#{workflow} keycloak-package must read the physical WebAuthn evidence from the environment's variables only"
  end
  if document.fetch("env", {}).keys.any? { |name| name.start_with?("PHYSICAL_WEBAUTHN_") } ||
      package_steps.any? { |step| step.key?("env") && step.fetch("run", "").include?("check-physical-webauthn-release.sh") } ||
      package_steps.any? { |step| step.fetch("run", "").include?("PHYSICAL_WEBAUTHN_") }
    abort "#{workflow} the physical WebAuthn gate must read only keycloak-package's environment variables"
  end

  download_index = package_steps.index do |step|
    step["uses"] == "actions/download-artifact@v5" && step.fetch("with", {})["name"] == "keycloak-ci-candidate" &&
      step.fetch("with", {})["run-id"] == "${{ needs.keycloak-build.outputs.ci-run }}"
  end
  gate_index = package_steps.index { |step| step.fetch("run", "").include?("tests/check-physical-webauthn-release.sh") }
  package_index = package_steps.index { |step| step.fetch("name", "") == "Package the tested image bytes" }
  upload_index = package_steps.index { |step| step.fetch("uses", "") == "actions/upload-artifact@v4" }
  unless download_index && gate_index && package_index && upload_index &&
      download_index < gate_index && gate_index < package_index && package_index < upload_index
    abort "#{workflow} must download the CI run's tested candidate, physically approve, package and upload it in that order"
  end
  packaging = package_steps.fetch(package_index).fetch("run", "")
  unless binds_to_build_outputs?(packaging) && packaging.include?('cp "$tested"')
    abort "#{workflow} packaging must package the tarball verified against keycloak-build's outputs"
  end
  if package_steps.any? { |step| step["uses"] == "docker/build-push-action@v7" }
    abort "#{workflow} keycloak-package must load the tested artifact, not rebuild it"
  end

  upload = package_steps.fetch(upload_index).fetch("with")
  unless upload["name"] == "keycloak-candidate-${{ github.sha }}" && upload["retention-days"] == 3
    abort "#{workflow} must bind the short-lived candidate artifact to the release commit"
  end

  download_index = publish_steps.index { |step| step.fetch("uses", "") == "actions/download-artifact@v5" }
  verify_index = publish_steps.index { |step| step.fetch("name", "") == "Verify and load the tested candidate" }
  login_index = publish_steps.index { |step| step.fetch("uses", "") == "docker/login-action@v4" }
  publish_index = publish_steps.index { |step| step.fetch("name", "") == "Publish the tested image bytes" }
  webhook_index = publish_steps.index { |step| step.fetch("name", "") == "Trigger the production Dokploy deployment" }
  unless download_index && verify_index && login_index && publish_index &&
      download_index < verify_index && verify_index < login_index && login_index < publish_index
    abort "#{workflow} keycloak-publish must verify the transferred bytes before registry login and publication"
  end
  unless webhook_index && publish_index < webhook_index
    abort "#{workflow} must trigger Dokploy only after the tested image bytes are published"
  end

  webhook = publish_steps.fetch(webhook_index)
  unless webhook["if"] == "github.ref == 'refs/heads/production'" &&
      webhook.fetch("env", {}).fetch("DOKPLOY_DEPLOY_HOOK", nil) == "${{ secrets.DOKPLOY_DEPLOY_HOOK }}"
    abort "#{workflow} Dokploy deployment must be production-only and read the DOKPLOY_DEPLOY_HOOK secret (keycloak-production's)"
  end
  webhook_command = webhook.fetch("run", "")
  unless webhook_command.include?('curl') && webhook_command.include?('DOKPLOY_DEPLOY_HOOK') &&
      webhook_command.include?('response_code')
    abort "#{workflow} Dokploy deployment must validate the webhook HTTP response"
  end

  verification = publish_steps.fetch(verify_index).fetch("run", "")
  for required_check in ["commit-sha", "sha256sum --check", "image-id", "e-skylab-theme-*.jar", "check-theme-contract.sh"]
    unless verification.include?(required_check)
      abort "#{workflow} publish verification is missing #{required_check}"
    end
  end
  unless binds_to_build_outputs?(verification)
    abort "#{workflow} publish verification must check the tarball and image against keycloak-build's outputs"
  end
  if publish_steps.any? { |step| step["uses"] == "docker/build-push-action@v7" }
    abort "#{workflow} keycloak-publish must load the tested artifact, not rebuild it"
  end

  source_guard = build_steps.find do |step|
    step.fetch("name", "") == "Require the release to point at current production"
  end&.fetch("run", "")
  unless source_guard&.include?("origin/production") && !source_guard.include?("origin/main")
    abort "#{workflow} must bind branch and version releases to current production"
  end
  # Re-runs of package or publish do not re-run keycloak-build: both check production again,
  # package before the physical WebAuthn gate, publish before it can log in to the registry.
  [[package_steps, gate_index, "keycloak-package", "the physical WebAuthn gate"],
   [publish_steps, login_index, "keycloak-publish", "the registry login"]].each do |steps, before_index, name, before|
    guard_index = steps.index { |step| step.fetch("name", "") == "Require the release to still point at current production" }
    guard = guard_index && steps.fetch(guard_index).fetch("run", "")
    unless guard && guard_index < before_index && guard.include?("git ls-remote --exit-code origin refs/heads/production") &&
        guard.include?('"$GITHUB_SHA"') && !guard.include?("main")
      abort "#{workflow} #{name} must check that the release still points at current production before #{before}"
    end
  end

  publication = publish_steps.fetch(publish_index).fetch("run", "")
  for alias_name in ["production", "latest"]
    unless publication.include?(%($PUBLISH_IMAGE:#{alias_name}))
      abort "#{workflow} tested Keycloak release must publish the #{alias_name} alias"
    end
  end
  unless publication.include?('$PUBLISH_IMAGE:sha-$GITHUB_SHA')
    abort "#{workflow} must publish an immutable commit alias"
  end
  if publication.include?('$PUBLISH_IMAGE:main')
    abort "#{workflow} must not publish production bytes through a main alias"
  end
  unless publication.include?('published_images=(') &&
      publication.include?('docker image inspect') &&
      publication.include?('docker buildx imagetools inspect --raw') &&
      publication.include?('test "$commit_digest" = "$alias_digest"')
    abort "#{workflow} all release aliases must be bound to the tested image ID and manifest digest"
  end
end

def assert_ci_branches(workflow)
  document = YAML.load_file(workflow, aliases: true)
  triggers = document[true] || document["on"]
  branches = triggers.fetch("push").fetch("branches")
  unless branches == ["main", "production"]
    abort "#{workflow} must validate both main and production pushes"
  end
end

# The CI matrix runs exactly the harness's groups, each with a timeout, and one job named
# integration passes only when all of them do. release.yml reads the same list from the harness
# (assert_release_candidate_flow).
def assert_integration_groups(workflow, harness)
  document = YAML.load_file(workflow, aliases: true)
  jobs = document.fetch("jobs")
  job = jobs.fetch("integration-group")
  harness_groups = File.read(harness, encoding: "UTF-8")[/^INTEGRATION_GROUPS=\(([^)]*)\)$/, 1].to_s.split
  abort "#{harness} must list its INTEGRATION_GROUPS" if harness_groups.empty?
  include = job.fetch("strategy").fetch("matrix").fetch("include")
  matrix_groups = include.map { |entry| entry.fetch("group") }
  unless matrix_groups.sort == harness_groups.sort
    abort "#{workflow} integration-group must run exactly the groups #{harness_groups.join(" ")} (runs #{matrix_groups.join(" ")})"
  end
  unless include.all? { |entry| entry.fetch("timeout", 0).is_a?(Integer) && entry["timeout"].positive? }
    abort "#{workflow} every integration group needs its own timeout"
  end
  unless job.fetch("env").fetch("INTEGRATION_GROUP") == "${{ matrix.group }}"
    abort "#{workflow} integration-group must pass its matrix group to the harness"
  end
  aggregate = jobs.fetch("integration")
  unless Array(aggregate.fetch("needs")).include?("integration-group") && aggregate.fetch("if") == "always()"
    abort "#{workflow} integration must wait for every group, also when one fails"
  end
end

# release.yml builds and tests nothing: keycloak-build finds the fully green full ci.yml run of the
# release tree (tests/find-green-full-ci-run.sh), downloads that run's candidate and every
# integration group's receipt and requires each receipt to name exactly those bytes and this
# tree; keycloak-package and keycloak-publish carry those bytes on (assert_release_boundary).
def assert_release_candidate_flow(workflow)
  document = YAML.load_file(workflow, aliases: true)
  jobs = document.fetch("jobs")
  build_job = jobs.fetch("keycloak-build")
  steps = build_job.fetch("steps")
  unless build_job.fetch("permissions", {}) == { "contents" => "read", "actions" => "read" }
    abort "#{workflow} keycloak-build reads the repository and CI's runs only"
  end
  test_image = build_job.fetch("env").fetch("KEYCLOAK_TEST_IMAGE")
  abort "#{workflow} keycloak-build must name the candidate image explicitly" if test_image.to_s.empty?
  if jobs.any? { |_, job| job.fetch("steps").any? { |step| step["uses"] == "docker/build-push-action@v7" || step.fetch("run", "").include?("bash tests/run-integration.sh") } }
    abort "#{workflow} must promote CI's tested candidate, not build or test one"
  end
  source_index = steps.index { |step| step.fetch("name", "") == "Require the release to point at current production" }
  run_index = steps.index { |step| step.fetch("name", "") == "Require a fully green full CI run of this tree" }
  static_index = steps.index { |step| step.fetch("run", "").include?("tests/check-fresh-runner.sh") }
  candidate_index = steps.index do |step|
    step["uses"] == "actions/download-artifact@v5" && step.fetch("with", {})["name"] == "keycloak-ci-candidate"
  end
  receipts_index = steps.index do |step|
    step["uses"] == "actions/download-artifact@v5" && step.fetch("with", {})["pattern"] == "keycloak-ci-tested-*"
  end
  verify_index = steps.index { |step| step.fetch("name", "") == "Require every integration group to have tested these bytes" }
  unless source_index && run_index && static_index && candidate_index && receipts_index && verify_index &&
      source_index < run_index && run_index < static_index && static_index < candidate_index &&
      candidate_index < receipts_index && receipts_index < verify_index
    abort "#{workflow} keycloak-build must check production, find the CI run, run static checks, download the candidate and receipts, then check them"
  end
  finder = steps.fetch(run_index)
  unless finder["id"] == "ci_run" && finder.fetch("run", "").include?('bash tests/find-green-full-ci-run.sh "$tree"') &&
      finder.fetch("run", "").include?('tree=$(git rev-parse "${GITHUB_SHA}^{tree}")')
    abort "#{workflow} keycloak-build must find the CI run of the release commit's tree with tests/find-green-full-ci-run.sh"
  end
  [candidate_index, receipts_index].each do |index|
    with = steps.fetch(index).fetch("with")
    unless with["run-id"] == "${{ steps.ci_run.outputs.run-id }}" && with["github-token"] == "${{ github.token }}"
      abort "#{workflow} keycloak-build must download the artifacts of the CI run it found"
    end
  end
  verification = steps.fetch(verify_index).fetch("run", "")
  ["INTEGRATION_GROUPS=", "sha256sum --check --strict", 'test "$(cat "$candidate_dir/tree")" = "$tree"',
   "group=%s\\ntree=%s\\nimage-id=%s\\nimage-sha256=%s\\n", "docker load",
   'test "$(find "$receipt_dir" -type f | wc -l | tr -d \' \')" = "${#group_list[@]}"'].each do |required_check|
    unless verification.include?(required_check)
      abort "#{workflow} candidate check is missing #{required_check}"
    end
  end
  outputs = build_job.fetch("outputs", {})
  unless outputs["ci-run"] == "${{ steps.ci_run.outputs.run-id }}" &&
      outputs["image-id"] == "${{ steps.candidate.outputs.image-id }}" &&
      outputs["image-sha256"] == "${{ steps.candidate.outputs.image-sha256 }}" && !outputs.fetch("version", "").to_s.empty?
    abort "#{workflow} keycloak-build must output the CI run, the checked image ID and SHA-256, and the version"
  end
end

# integration-all.yml runs the whole harness (INTEGRATION_GROUP=all) weekly and by hand; it only tests.
def assert_integration_all(workflow)
  document = YAML.load_file(workflow, aliases: true)
  triggers = document[true] || document["on"]
  unless triggers.keys.sort == ["schedule", "workflow_dispatch"]
    abort "#{workflow} must run only on its schedule and by hand"
  end
  unless document.fetch("permissions", nil) == { "contents" => "read" }
    abort "#{workflow} must read the repository only"
  end
  jobs = document.fetch("jobs")
  abort "#{workflow} must have the single job integration-all" unless jobs.keys == ["integration-all"]
  job = jobs.fetch("integration-all")
  unless job.fetch("env").fetch("INTEGRATION_GROUP") == "all" && !job.key?("permissions") && !job.key?("environment")
    abort "#{workflow} integration-all must run every stage, without its own permissions or an environment"
  end
  text = File.read(workflow, encoding: "UTF-8")
  if text.include?("secrets.") || text.include?("docker/login-action") || text =~ /push:\s*true/
    abort "#{workflow} must not read secrets, log in to a registry or push"
  end
end

# ci.yml: mode makes every run but a PR into main without full-ci full, except a production PR or
# push whose tree a fully green full run already tested (tests/find-green-full-ci-run.sh); gate
# checks mode against the event and waits for every job. A full run builds the candidate once,
# every integration group loads those bytes and uploads a receipt (the artifacts release.yml
# promotes). scope sees both sides of a rename.
def assert_ci_scope(ci)
  document = YAML.load_file(ci, aliases: true)
  jobs = document.fetch("jobs")
  eligible = "${{ (github.event_name != 'pull_request' || github.base_ref != 'main' || " \
    "contains(github.event.pull_request.labels.*.name, 'full-ci')) && 'true' || 'false' }}"
  production = "${{ ((github.event_name == 'pull_request' && github.base_ref == 'production') || " \
    "(github.event_name == 'push' && github.ref == 'refs/heads/production')) && 'true' || 'false' }}"
  mode_step = jobs.fetch("mode").fetch("steps").find { |step| step["id"] == "mode" }
  mode_run = mode_step&.fetch("run", "").to_s
  unless mode_step && mode_step.fetch("env", {})["ELIGIBLE"] == eligible && mode_step.fetch("env", {})["PRODUCTION"] == production &&
      mode_run.include?("full=$ELIGIBLE") && mode_run.include?('if [[ $ELIGIBLE == true && $PRODUCTION == true ]]; then') &&
      mode_run.include?('if promoted_from=$(bash tests/find-green-full-ci-run.sh "$tree") && [[ $promoted_from =~ ^[0-9]+$ ]]; then')
    abort "#{ci} mode must make every eligible run full unless it is a production run of a tree already tested in full"
  end
  scope = jobs.fetch("scope")
  unless scope.fetch("name") == "scope (${{ needs.mode.outputs.full == 'true' && 'full' || 'fast' }})" &&
      scope.fetch("needs") == "mode" &&
      scope.fetch("steps").any? { |step| step.fetch("env", {})["FULL"] == "${{ needs.mode.outputs.full }}" } &&
      scope.fetch("steps").any? { |step| step.fetch("run", "").include?("git diff --name-only --no-renames HEAD^1 HEAD") }
    abort "#{ci} scope must be named after mode's choice and see both sides of a rename"
  end
  gate = jobs.fetch("gate")
  unless gate.fetch("if") == "always()" && Array(gate.fetch("needs")).sort == (jobs.keys - ["gate"]).sort
    abort "#{ci} gate must wait for every other job, also when one fails"
  end
  gate_step = gate.fetch("steps").find { |step| step.fetch("name", "") == "Every selected job passed" }
  gate_run = gate_step&.fetch("run", "").to_s
  unless gate_step && gate_step.fetch("env", {})["ELIGIBLE"] == eligible && gate_step.fetch("env", {})["PRODUCTION"] == production &&
      gate_step.fetch("env", {})["FULL"] == "${{ needs.mode.outputs.full }}" &&
      gate_run.include?("true/*/true | false/*/false) ;;") &&
      gate_run.include?("true/true/false)\n    run_id=$(bash tests/find-green-full-ci-run.sh \"$(git rev-parse 'HEAD^{tree}')\")\n    [[ $run_id =~ ^[0-9]+$ ]]\n") &&
      gate_run.include?('($full == "true" or .value.result != "skipped")') &&
      gate_run.include?(%q(test "$(jq -r '.mode.result' <<<"$NEEDS")" = success))
    abort "#{ci} gate must check mode against the event, re-find a promoted tree's run, and allow skipped jobs only in a fast run"
  end
  aggregate = jobs.fetch("integration")
  unless Array(aggregate.fetch("needs")).sort == ["integration-group", "mode"] && aggregate.fetch("if") == "always()" &&
      aggregate.fetch("steps").first.fetch("env", {})["FULL"] == "${{ needs.mode.outputs.full }}"
    abort "#{ci} integration must wait for every group, also when one fails, and read mode's choice"
  end

  # A full run, or a fast pull request into main whose diff affects the harness (scope's affected),
  # builds the candidate and runs every group on it; mode is the one source of full.
  group_if = "needs.mode.outputs.full == 'true' || contains(format(' {0} ', needs.scope.outputs.affected), ' integration-group ')"
  candidate = jobs.fetch("candidate")
  steps = candidate.fetch("steps")
  static_index = steps.index { |step| step.fetch("run", "").include?("tests/check-fresh-runner.sh") }
  build_index = steps.index { |step| step["uses"] == "docker/build-push-action@v7" }
  save_index = steps.index { |step| step.fetch("run", "").include?("docker save") }
  upload_index = steps.index { |step| step["uses"] == "actions/upload-artifact@v4" }
  unless candidate.fetch("if") == group_if && Array(candidate.fetch("needs")).sort == %w[mode scope] &&
      static_index && build_index && save_index && upload_index &&
      static_index < build_index && build_index < save_index && save_index < upload_index &&
      steps.fetch(build_index).fetch("with")["tags"] == "${{ env.KEYCLOAK_TEST_IMAGE }}" &&
      steps.fetch(upload_index).fetch("with")["name"] == "keycloak-ci-candidate" &&
      steps.fetch(upload_index).fetch("with")["retention-days"] == 14
    abort "#{ci} candidate must build once in every full run, save the image and upload it for 14 days"
  end

  group = jobs.fetch("integration-group")
  steps = group.fetch("steps")
  env = group.fetch("env")
  unless group.fetch("if") == group_if && Array(group.fetch("needs")).sort == %w[candidate mode scope] &&
      env["KEYCLOAK_TEST_IMAGE"] == candidate.fetch("env").fetch("KEYCLOAK_TEST_IMAGE") &&
      env["IMAGE_ID"] == "${{ needs.candidate.outputs.image-id }}" &&
      env["IMAGE_SHA256"] == "${{ needs.candidate.outputs.image-sha256 }}"
    abort "#{ci} integration-group must test candidate's image in every full run"
  end
  static_index = steps.index { |step| step.fetch("run", "").include?("tests/check-fresh-runner.sh") }
  download_index = steps.index { |step| step["uses"] == "actions/download-artifact@v5" && step.fetch("with", {})["name"] == "keycloak-ci-candidate" }
  verify_index = steps.index { |step| step.fetch("name", "") == "Verify and load the built candidate" }
  integration_index = steps.index { |step| step.fetch("run", "").include?("bash tests/run-integration.sh") }
  record_index = steps.index { |step| step.fetch("name", "") == "Record the image this group tested" }
  receipt_index = steps.index { |step| step["uses"] == "actions/upload-artifact@v4" && step.fetch("with", {})["name"] == "keycloak-ci-tested-${{ matrix.group }}" }
  unless static_index && download_index && verify_index && integration_index && record_index && receipt_index &&
      static_index < download_index && download_index < verify_index && verify_index < integration_index &&
      integration_index < record_index && record_index < receipt_index
    abort "#{ci} integration-group must verify and load the candidate, test it, then record it"
  end
  if steps.any? { |step| step["uses"] == "docker/build-push-action@v7" }
    abort "#{ci} integration-group must load the built candidate, not rebuild it"
  end
  unless binds_to_build_outputs?(steps.fetch(verify_index).fetch("run", ""))
    abort "#{ci} integration-group must load the candidate verified against candidate's outputs"
  end
  if steps.fetch(integration_index).fetch("env", {}).key?("KEYCLOAK_TEST_IMAGE") ||
      [record_index, receipt_index].any? { |i| steps.fetch(i).key?("if") }
    abort "#{ci} integration-group must test its candidate and record it only when the harness passed"
  end
  record = steps.fetch(record_index).fetch("run", "")
  unless record.include?("group=%s\\ntree=%s\\nimage-id=%s\\nimage-sha256=%s\\n") && record.include?("git rev-parse 'HEAD^{tree}'")
    abort "#{ci} every group's receipt must name its group, the tree and the image it tested"
  end
end

# Affected tests: a fast run also runs every job of the whole suite whose own tests or config its
# diff touches, and all of them for a tests/ or config/ path no workflow reaches. tests/affected-
# jobs.sh lists the jobs with the tests/ scripts their steps run; the lists must equal the
# workflows, every whole-suite job must run on its own name in scope's affected output, every
# tracked tests/ and config/ file must be reached or local only, and sample changes must reach the
# right jobs.
def assert_affected_jobs(root, helper)
  workflows = File.join(root, ".github/workflows")
  ci = File.join(workflows, "ci.yml")
  jobs = YAML.load_file(ci, aliases: true).fetch("jobs")
  scripts_of = lambda do |job|
    job.fetch("steps").flat_map { |step| step.fetch("run", "").scan(%r{bash (?:\.\./)?(tests/[A-Za-z0-9_.-]+\.sh)}).flatten }.uniq.sort
  end
  listing = lambda do |option|
    output = `bash #{helper} #{option}`
    abort "#{helper} #{option} failed" unless $?.success?
    output
  end
  entries_of = ->(option) { listing.(option).lines.map(&:split).to_h { |words| [words.first, words.drop(1).sort] } }
  static_scripts = listing.("--static").split.sort
  unless static_scripts == scripts_of.(jobs.fetch("static"))
    abort "#{helper} STATIC_SCRIPTS must be exactly the scripts ci.yml's static job runs (#{scripts_of.(jobs.fetch("static")).join(" ")})"
  end
  # mode is the one source of full; candidate builds the image for integration-group and runs no
  # test of its own (checked with integration-group in assert_ci_scope).
  whole_suite = jobs.select { |name, job| name != "candidate" && job.fetch("if", "").to_s.start_with?("needs.mode.outputs.full == 'true'") }
  entries = entries_of.("--entries")
  unless entries.keys.sort == whole_suite.keys.sort
    abort "#{helper} must list exactly ci.yml's whole-suite jobs (#{whole_suite.keys.sort.join(" ")})"
  end
  whole_suite.each do |name, job|
    expected_if = "needs.mode.outputs.full == 'true' || contains(format(' {0} ', needs.scope.outputs.affected), ' #{name} ')"
    abort "#{ci} #{name} must also run when scope lists it as affected" unless job.fetch("if") == expected_if
    abort "#{ci} #{name} must need mode and scope" unless (%w[mode scope] - Array(job.fetch("needs"))).empty?
    unless (scripts_of.(job) - static_scripts) == entries.fetch(name)
      abort "#{helper} must list #{name} with the scripts it runs (#{(scripts_of.(job) - static_scripts).join(" ")})"
    end
  end
  fast = jobs.reject { |name, _| whole_suite.key?(name) || %w[static scope].include?(name) }
    .to_h { |name, job| [name, scripts_of.(job) - static_scripts] }.reject { |_, scripts| scripts.empty? }
  unless entries_of.("--fast") == fast
    abort "#{helper} FAST_ENTRIES must be exactly ci.yml's other jobs and their scripts (#{fast.map { |n, s| "#{n}: #{s.join(" ")}" }.join("; ")})"
  end
  ci_scripts = jobs.values.flat_map { |job| scripts_of.(job) }
  other = ["release.yml", "integration-all.yml"].flat_map do |name|
    YAML.load_file(File.join(workflows, name), aliases: true).fetch("jobs").values.flat_map { |job| scripts_of.(job) }
  end.uniq.sort - ci_scripts
  unless listing.("--other").split.sort == other
    abort "#{helper} OTHER_SCRIPTS must be exactly the scripts only release.yml and integration-all.yml run (#{other.join(" ")})"
  end
  # EXTRA_EDGES: every test that calls config/ scripts dynamically ("/tmp/config/$x",
  # "$CONFIG_DIR/$x", "$IN_CONTAINER_CONFIG/$x") is an edge whose targets include every config/
  # script its code names; a test that sets KEYCLOAK_RECONCILE_ONLY and names the operator step
  # role-groups or leader-app-roles (the reconciler execs "$CONFIG_DIR/$RECONCILE_ONLY.sh") has
  # both as targets. Static checks
  # (STATIC_SCRIPTS) are tested in every run and need no edge.
  edges = listing.("--edges").lines.map(&:split).to_h { |words| [words.first, words.drop(1)] }
  code = ->(path) { File.readlines(File.join(root, path), encoding: "UTF-8").reject { |line| line =~ /\A\s*#/ }.join }
  dynamic = %r{(?:/tmp/config|/opt/keycloak/(?:sky-)?config|\$\{?CONFIG_DIR\}?|\$\{?IN_CONTAINER_CONFIG\}?)/"?\$}
  config_scripts = Dir.children(File.join(root, "config")).grep(/\.sh\z/)
  Dir.glob(File.join(root, "tests/*.sh")).map { |path| path.delete_prefix("#{root}/") }.sort.each do |path|
    next if static_scripts.include?(path) || path == "tests/affected-jobs.sh"
    text = code.(path)
    needed = []
    if text.match?(dynamic)
      needed += text.scan(/(?<![A-Za-z0-9_\/-])([a-z][a-z0-9-]*\.sh)\b/).flatten.uniq.select { |name| config_scripts.include?(name) }
        .map { |name| "config/#{name}" } - ["config/reconcile-account-center.sh"]
    end
    if text.include?("KEYCLOAK_RECONCILE_ONLY=") && text.match?(/(?<![A-Za-z0-9_\/.-])(?:role-groups|leader-app-roles)(?![A-Za-z0-9_.-])/)
      needed += %w[config/role-groups.sh config/leader-app-roles.sh]
    end
    next if needed.empty?
    missing = needed.uniq - edges.fetch(path, [])
    unless missing.empty?
      abort "#{helper} EXTRA_EDGES must give #{path} the config scripts it runs dynamically (#{missing.join(" ")})"
    end
  end
  reconcile = code.("config/reconcile-account-center.sh")
  unless reconcile.include?('if [[ $RECONCILE_ONLY == role-groups || $RECONCILE_ONLY == leader-app-roles ]]; then') &&
      reconcile.scan('"$CONFIG_DIR/$RECONCILE_ONLY.sh"').length == 1 && reconcile.scan(dynamic).length == 1
    abort "#{helper}: the reconciler's only dynamic call must be the operator steps role-groups and leader-app-roles"
  end
  unreached = listing.("--unreached").split
  unless unreached.empty?
    abort "#{helper}: no workflow reaches #{unreached.join(" ")}; run it from a job or list it in LOCAL_ONLY"
  end
  scope_run = jobs.fetch("scope").fetch("steps").map { |step| step.fetch("run", "") }.join("\n")
  unless scope_run.include?('affected=$(bash tests/affected-jobs.sh <<<"$changed")') &&
      scope_run.include?("bash tests/affected-jobs.sh --entries")
    abort "#{ci} scope must name the affected jobs of a fast run, and every one when its diff cannot be read"
  end
  # Only a pull request into main has affected jobs: a fast production run promotes a tree a full
  # run already tested, and its diff (everything main gained since the last release) would start
  # the whole suite again.
  affected_run = "${{ (github.event_name == 'pull_request' && github.base_ref == 'main') && 'true' || 'false' }}"
  unless jobs.fetch("scope").fetch("steps").any? { |step| step.fetch("env", {})["AFFECTED_RUN"] == affected_run } &&
      scope_run.include?("all=' '\n  if [[ $FULL == true || $AFFECTED_RUN == true ]]; then\n    all=\" $(bash tests/affected-jobs.sh --entries") &&
      scope_run.include?("affected=' '\nif [[ $AFFECTED_RUN == true ]]; then\n  affected=$(bash tests/affected-jobs.sh <<<\"$changed\")\nfi\n")
    abort "#{ci} scope must list affected jobs only in a pull request into main (a fast production run has none)"
  end
  # The sample paths are split ("tests/" "x") so that this script's own text names none of them.
  everything = whole_suite.keys
  reaches = {
    "tests/" "kcadm-core-roles-failure.sh" => %w[role-groups dk-read-only integration-group],
    "tests/" "core-service-roles.sh" => %w[integration-group],
    "tests/" "fixture-realm.json" => %w[integration-group],
    "tests/" "dk-read-only.sh" => %w[dk-read-only],
    "tests/" "run-integration.sh" => %w[integration-group],
    "theme/tests/" "integration/real-keycloak.spec.ts" => %w[integration-group],
    "config/" "reconcile-account-center.sh" => %w[integration-group role-groups dk-read-only login-clients],
    "config/" "not-read-by-any-job.sh" => everything,
    "tests/" "not-run-by-any-job.sh" => everything,
  }
  # Exactly these (a narrow config file, and paths no whole-suite job reads: a comment-only mention,
  # the static checks, a fast job's config, docs, local only, theme sources).
  exactly = {
    "config/" "sandbox-admin-local-client.sh" => %w[sandbox-admin-local-client],
    "config/" "role-groups.json" => %w[role-groups],
    "config/" "leader-app-roles.sh" => %w[role-groups],
    "config/" "sandbox-site-clients.sh" => %w[login-clients],
    "config/" "skyapp-cms-editor.sh" => %w[skyapp-cms-editor login-clients],
    "docs/x.md" => [], "tests/" "check-fresh-runner.sh" => [], "tests/" "microsoft-reauthentication.sh" => [],
    "tests/" "welcome-page.sh" => [], "config/" "create-place-client.sh" => [], "tests/" "sudo-email-code.sh" => [],
    "theme/src/login/x.tsx" => [],
  }
  paths = reaches.keys + exactly.keys
  output = IO.popen(["bash", helper, "--each"], "r+") { |io| io.puts(paths); io.close_write; io.read }
  abort "#{helper} --each failed" unless $?.success?
  got = output.lines.to_h { |line| path, jobs = line.chomp.split(":", 2); [path, jobs.to_s.split] }
  reaches.each do |path, expected|
    missing = expected - got.fetch(path, [])
    abort "#{helper} does not reach #{missing.join(" ")} from #{path}" unless missing.empty?
  end
  exactly.each do |path, expected|
    unless got.fetch(path, nil).to_a.sort == expected.sort
      abort "#{helper} must run exactly #{expected.join(" ")} for #{path} (runs #{got.fetch(path, []).join(" ")})"
    end
  end
end

assert_affected_jobs(root, File.join(root, "tests/affected-jobs.sh"))

# The finder ci.yml and release.yml share: only push, schedule and workflow_dispatch runs (a
# pull_request run tests GitHub's merge commit), every page, a passed "scope (full)" and no job
# that did not pass.
def assert_finder(finder)
  text = File.read(finder, encoding: "UTF-8")
  ['gh api --paginate -X GET "repos/$repository/actions/workflows/ci.yml/runs"',
   '-f status=success',
   'select(.event == "push" or .event == "schedule" or .event == "workflow_dispatch")',
   'head_tree=$(gh api "repos/$repository/git/commits/$head_sha" --jq .tree.sha)',
   '[[ $head_tree == "$tree" ]] || continue',
   'gh api --paginate "repos/$repository/actions/runs/$run_id/jobs?per_page=100"',
   "grep -qxF 'success scope (full)' <<<\"$jobs\" && ! grep -qv '^success ' <<<\"$jobs\""].each do |required|
    abort "#{finder} is missing #{required}" unless text.include?(required)
  end
  abort "#{finder} must never accept pull_request runs" if text.include?('.event == "pull_request"')
  # Not found is a failure, and a run whose candidate or a receipt expired is no evidence.
  unless text.lines.map(&:strip).reject(&:empty?).last == "exit 1"
    abort "#{finder} must exit 1 when no run is found"
  end
  ['--jq \'.artifacts[] | select(.expired == false) | .name\'', "required_artifacts=(keycloak-ci-candidate)",
   'required_artifacts+=("keycloak-ci-tested-$group")', "INTEGRATION_GROUPS="].each do |required|
    abort "#{finder} must require the run's live candidate and receipts (#{required})" unless text.include?(required)
  end
end

# Workflow hygiene (regressions, not a security boundary: a branch's own workflow escapes any
# check here; the boundary is the environment's branch policy, rulesets and the package's access).
# Every workflow (.yml or .yaml): no pull_request_target or workflow_run trigger; every job names
# its permissions (or the workflow does), never write-all; only release.yml's keycloak-publish
# writes packages; only release.yml's keycloak-package and keycloak-publish run in an environment;
# release.yml has no workflow-level env or permissions, and among its jobs only keycloak-publish
# reads a secret; no other workflow reads one.
# Expression names are case-insensitive: any ${{ … }} naming the secrets context, and secrets: inherit.
secret_use = /\$\{\{[^}]*\bsecrets\b|\bsecrets\s*:\s*inherit/i
Dir.glob(File.join(root, ".github/workflows/*.{yml,yaml}")).sort.each do |workflow|
  name = File.basename(workflow)
  document = YAML.load_file(workflow, aliases: true)
  triggers = document[true] || document["on"]
  trigger_names = triggers.is_a?(Hash) ? triggers.keys : Array(triggers)
  if (trigger_names.map(&:to_s) & %w[pull_request_target workflow_run]).any?
    abort "#{workflow} must not run on pull_request_target or workflow_run"
  end
  if document["permissions"].to_s.include?("write-all")
    abort "#{workflow} must not grant write-all"
  end
  if name == "release.yml" && (document.key?("env") || document.key?("permissions"))
    abort "#{workflow} must not set workflow-level env or permissions"
  end
  document.fetch("jobs").each do |job_name, job|
    permissions = job.key?("permissions") ? job["permissions"] : document["permissions"]
    if permissions.nil?
      abort "#{workflow} #{job_name} must name its permissions (the repository default may be write)"
    end
    if permissions.to_s.include?("write-all") || permissions.to_s.include?("read-all")
      abort "#{workflow} #{job_name} must name each permission, not write-all or read-all"
    end
    writes_packages = permissions.is_a?(Hash) && permissions["packages"].to_s.strip == "write"
    if writes_packages && !(name == "release.yml" && job_name == "keycloak-publish")
      abort "#{workflow} #{job_name} must not write packages"
    end
    if job.key?("environment") && !(name == "release.yml" && %w[keycloak-package keycloak-publish].include?(job_name))
      abort "#{workflow} #{job_name} must not run in an environment"
    end
    job_text = job.to_s
    unless name == "release.yml" && job_name == "keycloak-publish"
      if job_text.match?(secret_use) || job_text.match?(/dokploy/i)
        abort "#{workflow} #{job_name} must not read secrets or deploy"
      end
      # A reusable workflow call (uses:) or passed secrets (secrets:) would carry this job's
      # secrets elsewhere.
      if job.key?("uses") || job.key?("secrets")
        abort "#{workflow} #{job_name} must not call a reusable workflow or pass secrets"
      end
    end
  end
  text = File.read(workflow, encoding: "UTF-8")
  if name != "release.yml" && (text.match?(secret_use) || text.match?(/dokploy/i))
    abort "#{workflow} must not read secrets or deploy"
  end
end

assert_finder(File.join(root, "tests/find-green-full-ci-run.sh"))
assert_ci_branches(File.join(root, ".github/workflows/ci.yml"))
assert_ci_scope(File.join(root, ".github/workflows/ci.yml"))
assert_integration_groups(File.join(root, ".github/workflows/ci.yml"), File.join(root, "tests/run-integration.sh"))
assert_release_candidate_flow(File.join(root, ".github/workflows/release.yml"))
assert_release_boundary(File.join(root, ".github/workflows/release.yml"))
assert_order(File.join(root, ".github/workflows/integration-all.yml"), "integration-all")
assert_integration_all(File.join(root, ".github/workflows/integration-all.yml"))
RUBY

printf 'Fresh-runner portability, explicit candidate wiring and workflow order checks passed.\n'
