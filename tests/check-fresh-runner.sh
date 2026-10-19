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
  ["keycloak-build", "keycloak-integration", "keycloak-package", "keycloak-publish"].each do |name|
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
  unless Array(package_job.fetch("needs", nil)).sort == ["keycloak-build", "keycloak-integration"]
    abort "#{workflow} keycloak-package must run only when the build and every integration group passed"
  end
  unless package_job.fetch("environment", nil) == "keycloak-production"
    abort "#{workflow} keycloak-package must read the physical WebAuthn evidence of the keycloak-production environment"
  end

  receipts_index = package_steps.index { |step| step.fetch("name", "") == "Require every integration group to have tested these bytes" }
  gate_index = package_steps.index { |step| step.fetch("run", "").include?("tests/check-physical-webauthn-release.sh") }
  package_index = package_steps.index { |step| step.fetch("name", "") == "Package the tested image bytes" }
  upload_index = package_steps.index { |step| step.fetch("uses", "") == "actions/upload-artifact@v4" }
  unless receipts_index && gate_index && package_index && upload_index &&
      receipts_index < gate_index && gate_index < package_index && package_index < upload_index
    abort "#{workflow} must check every group's receipt, physically approve, package and upload the candidate in that order"
  end
  receipts = package_steps.fetch(receipts_index).fetch("run", "")
  for required_check in ["INTEGRATION_GROUPS=", "$IMAGE_ID", "$IMAGE_SHA256", "$GITHUB_SHA"]
    unless receipts.include?(required_check)
      abort "#{workflow} receipt check is missing #{required_check}"
    end
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
    abort "#{workflow} Dokploy deployment must be production-only and use the repository secret"
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
  unless aggregate.fetch("needs") == "integration-group" && aggregate.fetch("if") == "always()"
    abort "#{workflow} integration must wait for every group, also when one fails"
  end
end

# release.yml builds the candidate once (keycloak-build), runs the harness's groups on the saved
# bytes in parallel (keycloak-integration, the matrix read from the harness's INTEGRATION_GROUPS
# list by keycloak-build) and packages those bytes only after every group passed (keycloak-package,
# checked in assert_release_boundary). Nothing after keycloak-build builds an image.
def assert_release_candidate_flow(workflow)
  document = YAML.load_file(workflow, aliases: true)
  jobs = document.fetch("jobs")
  sha_artifact = "keycloak-test-candidate-${{ github.sha }}"

  build_job = jobs.fetch("keycloak-build")
  build_steps = build_job.fetch("steps")
  test_image = build_job.fetch("env").fetch("KEYCLOAK_TEST_IMAGE")
  abort "#{workflow} keycloak-build must name the candidate image explicitly" if test_image.to_s.empty?
  static_index = build_steps.index { |step| step.fetch("run", "").include?("tests/check-fresh-runner.sh") }
  groups_index = build_steps.index { |step| step.fetch("run", "").include?("INTEGRATION_GROUPS=") }
  build_indexes = build_steps.each_index.select { |i| build_steps[i]["uses"] == "docker/build-push-action@v7" }
  save_index = build_steps.index { |step| step.fetch("run", "").include?("docker save") }
  upload_index = build_steps.index { |step| step["uses"] == "actions/upload-artifact@v4" }
  unless static_index && groups_index && build_indexes.length == 1 && save_index && upload_index &&
      static_index < build_indexes.first && build_indexes.first < save_index && save_index < upload_index
    abort "#{workflow} keycloak-build must run fresh-runner static checks, build once, then save and upload the candidate"
  end
  build = build_steps.fetch(build_indexes.first).fetch("with")
  unless build["load"] == true && build["tags"] == "${{ env.KEYCLOAK_TEST_IMAGE }}"
    abort "#{workflow} keycloak-build must load the exact KEYCLOAK_TEST_IMAGE it saves"
  end
  if build_steps.any? { |step| step.fetch("run", "").include?("bash tests/run-integration.sh") }
    abort "#{workflow} keycloak-build must leave the harness to keycloak-integration"
  end
  upload = build_steps.fetch(upload_index).fetch("with")
  unless upload["name"] == sha_artifact && upload["retention-days"] == 3
    abort "#{workflow} must bind the short-lived test candidate artifact to the release commit"
  end
  outputs = build_job.fetch("outputs", {})
  for output in ["version", "integration-groups", "image-id", "image-sha256"]
    abort "#{workflow} keycloak-build must output #{output}" if outputs.fetch(output, "").to_s.empty?
  end

  job = jobs.fetch("keycloak-integration")
  steps = job.fetch("steps")
  strategy = job.fetch("strategy")
  unless job.fetch("needs") == "keycloak-build" &&
      strategy.fetch("matrix") == { "group" => "${{ fromJSON(needs.keycloak-build.outputs.integration-groups) }}" } &&
      strategy.fetch("fail-fast") == false
    abort "#{workflow} keycloak-integration must run every harness group from keycloak-build, also when one fails"
  end
  unless job.fetch("timeout-minutes", 0).is_a?(Integer) && job["timeout-minutes"].positive?
    abort "#{workflow} keycloak-integration needs a timeout"
  end
  env = job.fetch("env")
  unless env.fetch("INTEGRATION_GROUP") == "${{ matrix.group }}" && env.fetch("KEYCLOAK_TEST_IMAGE") == test_image &&
      env.fetch("IMAGE_ID") == "${{ needs.keycloak-build.outputs.image-id }}" &&
      env.fetch("IMAGE_SHA256") == "${{ needs.keycloak-build.outputs.image-sha256 }}"
    abort "#{workflow} keycloak-integration must test keycloak-build's candidate in its matrix group"
  end
  static_index = steps.index { |step| step.fetch("run", "").include?("tests/check-fresh-runner.sh") }
  download_index = steps.index { |step| step["uses"] == "actions/download-artifact@v5" && step.fetch("with", {})["name"] == sha_artifact }
  verify_index = steps.index { |step| step.fetch("name", "") == "Verify and load the built candidate" }
  integration_index = steps.index { |step| step.fetch("run", "").include?("bash tests/run-integration.sh") }
  receipt_index = steps.index { |step| step["uses"] == "actions/upload-artifact@v4" }
  unless static_index && download_index && verify_index && integration_index && receipt_index &&
      static_index < download_index && download_index < verify_index && verify_index < integration_index &&
      integration_index < receipt_index
    abort "#{workflow} keycloak-integration must run static checks, verify and load the candidate, test it, then record it"
  end
  verification = steps.fetch(verify_index).fetch("run", "")
  unless binds_to_build_outputs?(verification) && verification.include?("docker load")
    abort "#{workflow} keycloak-integration must load the candidate verified against keycloak-build's outputs"
  end
  if steps.any? { |step| step["uses"] == "docker/build-push-action@v7" }
    abort "#{workflow} keycloak-integration must load the built candidate, not rebuild it"
  end
  if steps.fetch(integration_index).fetch("env", {}).key?("KEYCLOAK_TEST_IMAGE")
    abort "#{workflow} keycloak-integration must not override the job's tested candidate in the integration step"
  end
  receipt = steps.fetch(receipt_index).fetch("with")
  unless receipt["name"] == "keycloak-tested-${{ github.sha }}-${{ matrix.group }}" && receipt["retention-days"] == 3
    abort "#{workflow} every group's receipt must be bound to the release commit and its group"
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

# ci.yml: pushes, PRs into production, the schedule, manual runs and full-ci PRs are full runs;
# only PRs into main may skip jobs (scope). gate waits for every job, and the integration groups
# run only in a full run. release.yml requires a fully green full ci.yml run of the release tree
# before it builds.
def assert_ci_scope(ci, release)
  document = YAML.load_file(ci, aliases: true)
  jobs = document.fetch("jobs")
  full = "(github.event_name != 'pull_request' || github.base_ref != 'main' || " \
    "contains(github.event.pull_request.labels.*.name, 'full-ci'))"
  scope = jobs.fetch("scope")
  unless scope.fetch("name") == "scope (${{ #{full} && 'full' || 'fast' }})" &&
      scope.fetch("steps").any? { |step| step.fetch("env", {})["FULL"] == "${{ #{full} && 'true' || 'false' }}" }
    abort "#{ci} scope must call every run but a pull request into main without full-ci a full run"
  end
  unless scope.fetch("steps").any? { |step| step.fetch("run", "").include?("git diff --name-only --no-renames HEAD^1 HEAD") }
    abort "#{ci} scope must see both sides of a rename"
  end
  gate = jobs.fetch("gate")
  unless gate.fetch("if") == "always()" && Array(gate.fetch("needs")).sort == (jobs.keys - ["gate"]).sort
    abort "#{ci} gate must wait for every other job, also when one fails"
  end
  # gate and integration read full or fast from the event, as scope does, not from scope's output.
  ["gate", "integration"].each do |name|
    step = jobs.fetch(name).fetch("steps").first
    unless step.fetch("env", {})["FULL"] == "${{ #{full} && 'true' || 'false' }}"
      abort "#{ci} #{name} must read full or fast from the same expression as scope"
    end
  end
  gate_run = jobs.fetch("gate").fetch("steps").first.fetch("run", "")
  unless gate_run.include?('test "$SCOPE_FULL" = "$FULL"') &&
      gate_run.include?('($full == "true" or .value.result != "skipped")')
    abort "#{ci} gate must agree with scope and allow skipped jobs only in a fast run"
  end
  unless jobs.fetch("integration-group").fetch("if").start_with?("needs.scope.outputs.full == 'true' || ")
    abort "#{ci} integration-group must run in every full run"
  end
  build_steps = YAML.load_file(release, aliases: true).fetch("jobs").fetch("keycloak-build").fetch("steps")
  guard_index = build_steps.index { |step| step.fetch("name", "") == "Require a fully green full CI run of this tree" }
  build_index = build_steps.index { |step| step["uses"] == "docker/build-push-action@v7" }
  guard = guard_index && build_steps.fetch(guard_index).fetch("run", "")
  unless guard && guard_index < build_index && guard.include?("success scope (full)") &&
      guard.include?("^{tree}") && guard.include?("grep -qv '^success '") &&
      guard.include?("gh api --paginate -X GET") &&
      guard.include?('select(.event == "push" or .event == "schedule" or .event == "workflow_dispatch")')
    abort "#{release} keycloak-build must require a fully green full CI run of the release tree before it builds"
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
  whole_suite = jobs.select { |_, job| job.fetch("if", "").to_s.start_with?("needs.scope.outputs.full == 'true'") }
  entries = entries_of.("--entries")
  unless entries.keys.sort == whole_suite.keys.sort
    abort "#{helper} must list exactly ci.yml's whole-suite jobs (#{whole_suite.keys.sort.join(" ")})"
  end
  whole_suite.each do |name, job|
    expected_if = "needs.scope.outputs.full == 'true' || contains(format(' {0} ', needs.scope.outputs.affected), ' #{name} ')"
    abort "#{ci} #{name} must also run when scope lists it as affected" unless job.fetch("if") == expected_if
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
assert_ci_branches(File.join(root, ".github/workflows/ci.yml"))
assert_ci_scope(File.join(root, ".github/workflows/ci.yml"), File.join(root, ".github/workflows/release.yml"))
assert_order(File.join(root, ".github/workflows/ci.yml"), "integration-group")
assert_integration_groups(File.join(root, ".github/workflows/ci.yml"), File.join(root, "tests/run-integration.sh"))
assert_release_candidate_flow(File.join(root, ".github/workflows/release.yml"))
assert_release_boundary(File.join(root, ".github/workflows/release.yml"))
assert_order(File.join(root, ".github/workflows/integration-all.yml"), "integration-all")
assert_integration_all(File.join(root, ".github/workflows/integration-all.yml"))
RUBY

printf 'Fresh-runner portability, explicit candidate wiring and workflow order checks passed.\n'
