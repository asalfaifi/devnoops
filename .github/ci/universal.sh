#!/usr/bin/env bash
set -Eeuo pipefail

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${ENGINE_ROOT}/.github/ci/bin:/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:${HOME}/go/bin:${PATH}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export NPM_CONFIG_FUND=false
export NPM_CONFIG_AUDIT=false
export DOCKER_CONFIG="${RUNNER_TEMP:-/tmp}/universal-ci-docker"
export UNIVERSAL_CI_HELM_HOME="${RUNNER_TEMP:-/tmp}/universal-ci-helm-home"

mkdir -p "$DOCKER_CONFIG" "$UNIVERSAL_CI_HELM_HOME"
if [[ ! -f "$DOCKER_CONFIG/config.json" ]]; then
  printf '{"auths":{}}\n' > "$DOCKER_CONFIG/config.json"
fi

docker() {
  command docker --config "$DOCKER_CONFIG" "$@"
}

# Helm's OCI client otherwise falls back to ~/.docker/config.json. On a
# headless macOS runner that can invoke the desktop credential helper and fail
# against the locked login keychain even for public dependencies. Isolate only
# Helm's HOME; other build tools retain the runner account's normal caches.
helm() {
  HOME="$UNIVERSAL_CI_HELM_HOME" DOCKER_CONFIG="$DOCKER_CONFIG" command helm "$@"
}

PHASE="${1:-}"
ROOT="${GITHUB_WORKSPACE:-$(git rev-parse --show-toplevel)}"
ARTIFACTS="${ROOT}/.ci-artifacts/${PHASE}"
PYTHON="${UNIVERSAL_CI_PYTHON:-$(command -v python3.12 || command -v python3)}"
FULL_SCAN="${UNIVERSAL_CI_FULL_SCAN:-false}"
BASE_SHA="${UNIVERSAL_CI_BASE_SHA:-}"

mkdir -p "$ARTIFACTS"
cd "$ROOT"

if [[ -f "$ROOT/.github/ci.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.github/ci.env"
  set +a
fi

log() { printf '\n[%s] %s\n' "$PHASE" "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
die() { printf '::error::%s\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

acquire_host_lock() {
  local lock="${UNIVERSAL_CI_HOST_LOCK:-/tmp/universal-ci-host.lock}" owner attempt
  for attempt in {1..1440}; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/pid"
      trap 'rm -rf "${UNIVERSAL_CI_HOST_LOCK:-/tmp/universal-ci-host.lock}"' EXIT INT TERM
      return 0
    fi
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    if ((attempt % 12 == 0)); then
      log "Waiting for another repository job on this Mac (owner PID ${owner:-unknown})"
    fi
    sleep 5
  done
  die "Timed out waiting for the host-wide CI lock"
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  case "$PHASE" in
    test|security|build|readiness)
      acquire_host_lock
      ;;
  esac
fi

is_ignored_path() {
  case "$1" in
    _universal-ci/*|.vib/*|vendor/*|third_party/*|node_modules/*|.venv/*|*/node_modules/*|*/.venv/*|testdata/*|*/testdata/*|examples/*|*/examples/*)
      return 0 ;;
  esac
  return 1
}

is_json_with_extensions() {
  case "$1" in
    .vib/*|tsconfig*.json|*/tsconfig*.json|jsconfig*.json|*/jsconfig*.json|.vscode/*.json|*/.vscode/*.json|.devcontainer/*.json|*/.devcontainer/*.json)
      return 0 ;;
  esac
  return 1
}

tracked_files() {
  git ls-files "$@" | while IFS= read -r file; do
    is_ignored_path "$file" || printf '%s\n' "$file"
  done
}

changed_files() {
  local base="$BASE_SHA"
  if [[ -n "$base" && "$base" != "0000000000000000000000000000000000000000" ]] && git cat-file -e "${base}^{commit}" 2>/dev/null; then
    git diff --name-only "${base}...HEAD"
  elif git rev-parse HEAD^ >/dev/null 2>&1; then
    git diff --name-only HEAD^ HEAD
  else
    git ls-files
  fi
}

list_go_modules() {
  tracked_files go.mod '*/go.mod' | sed 's#/go.mod$##; s#^go.mod$#.#' | sort -u
}

list_node_projects() {
  if [[ -f package.json ]] && { [[ -f pnpm-workspace.yaml ]] || jq -e '.workspaces != null' package.json >/dev/null 2>&1; }; then
    printf '.\n'
    return
  fi
  tracked_files package.json '*/package.json' | sed 's#/package.json$##; s#^package.json$#.#' | sort -u
}

list_python_projects() {
  tracked_files pyproject.toml '*/pyproject.toml' | sed 's#/pyproject.toml$##; s#^pyproject.toml$#.#' | sort -u
}

list_unity_projects() {
  tracked_files '*/ProjectSettings/ProjectVersion.txt' | sed 's#/ProjectSettings/ProjectVersion.txt$##' | sort -u
}

list_dockerfiles() {
  tracked_files Dockerfile 'Dockerfile.*' '*/Dockerfile' '*/Dockerfile.*' '*/*/Dockerfile' '*/*/Dockerfile.*' |
    awk 'BEGIN { FS="/" } !/\.dockerignore$/ && (NF <= 2 || ($1 != "docker" && $1 != "bitnami"))' |
    sort -u
}

project_hash() {
  local dir="$1"
  (
    cd "$dir"
    for file in requirements-dev.lock requirements.lock requirements-dev.txt requirements.txt pyproject.toml; do
      [[ -f "$file" ]] && shasum -a 256 "$file"
    done
  ) | shasum -a 256 | awk '{print $1}'
}

python_venv() {
  local dir="$1" hash cache marker
  hash="$(project_hash "$dir")"
  cache="${HOME}/.cache/universal-ci/python/${GITHUB_REPOSITORY:-local}/${hash}"
  marker="${cache}/.ready"
  if [[ ! -x "${cache}/bin/python" || ! -f "$marker" ]]; then
    {
      rm -rf "$cache"
      "$PYTHON" -m venv "$cache"
      "${cache}/bin/python" -m pip install --upgrade 'pip>=25,<27' wheel
      if [[ -f "$dir/requirements-dev.lock" ]]; then
        "${cache}/bin/python" -m pip install --requirement "$dir/requirements-dev.lock"
      elif [[ -f "$dir/requirements-dev.txt" ]]; then
        "${cache}/bin/python" -m pip install --requirement "$dir/requirements-dev.txt"
      elif [[ -f "$dir/requirements.lock" ]]; then
        "${cache}/bin/python" -m pip install --requirement "$dir/requirements.lock"
      elif [[ -f "$dir/requirements.txt" ]]; then
        "${cache}/bin/python" -m pip install --requirement "$dir/requirements.txt"
      fi
      "${cache}/bin/python" -m pip install ruff pytest pip-audit bandit build
      touch "$marker"
    } >&2
  fi
  printf '%s\n' "$cache"
}

npm_install() {
  local dir="$1"
  if [[ -f "$dir/package-lock.json" ]]; then
    (cd "$dir" && npm ci --no-audit --no-fund)
  elif [[ -f "$dir/pnpm-lock.yaml" ]] && have pnpm; then
    (cd "$dir" && pnpm install --frozen-lockfile)
  elif [[ -f "$dir/yarn.lock" ]] && have yarn; then
    (cd "$dir" && yarn install --immutable)
  else
    (cd "$dir" && npm install --no-audit --no-fund)
  fi
}

npm_audit() {
  local dir="$1" yarn_major
  if [[ -f "$dir/package-lock.json" || -f "$dir/npm-shrinkwrap.json" ]]; then
    (cd "$dir" && npm audit --omit=dev --audit-level=high)
  elif [[ -f "$dir/pnpm-lock.yaml" ]] && have pnpm; then
    (cd "$dir" && pnpm audit --prod --audit-level=high)
  elif [[ -f "$dir/yarn.lock" ]] && have yarn; then
    yarn_major="$(yarn --version | cut -d. -f1)"
    if [[ "$yarn_major" == "1" ]]; then
      (cd "$dir" && yarn audit --groups dependencies --level high)
    else
      (cd "$dir" && yarn npm audit --environment production --severity high)
    fi
  else
    (cd "$dir" && npm audit --omit=dev --audit-level=high)
  fi
}

npm_has_script() {
  local dir="$1" script="$2"
  jq -e --arg script "$script" '.scripts[$script] != null' "$dir/package.json" >/dev/null 2>&1
}

npm_run_if_present() {
  local dir="$1" script="$2"
  if npm_has_script "$dir" "$script"; then
    log "npm ${script} (${dir})"
    (cd "$dir" && npm run "$script")
  fi
}

unity_editor() {
  local project="$1" version
  version="$(awk '/m_EditorVersion:/ {print $2}' "$project/ProjectSettings/ProjectVersion.txt")"
  printf '/Applications/Unity/Hub/Editor/%s/Unity.app/Contents/MacOS/Unity\n' "$version"
}

helm_chart_dirs() {
  local charts changed chart shards shard_index
  charts="$(tracked_files Chart.yaml '*/Chart.yaml' '*/*/Chart.yaml' '*/*/*/Chart.yaml' || true)"
  if [[ "$FULL_SCAN" == "true" || "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
    shards="${UNIVERSAL_CI_HELM_SHARDS:-1}"
    [[ "$shards" =~ ^[1-9][0-9]*$ ]] || die "UNIVERSAL_CI_HELM_SHARDS must be a positive integer"
    shard_index=$((10#$(date -u +%V) % shards))
    printf '%s\n' "$charts" | sed '/^$/d; s#/Chart.yaml$##' |
      awk -v shards="$shards" -v shard_index="$shard_index" '((NR - 1) % shards) == shard_index'
    return
  fi
  changed="$(changed_files)"
  while IFS= read -r chart; do
    [[ -n "$chart" ]] || continue
    chart="${chart%/Chart.yaml}"
    if grep -Eq "^${chart//./\\.}/" <<< "$changed"; then
      printf '%s\n' "$chart"
    fi
  done <<< "$charts"
}

build_helm_dependencies() {
  local chart="$1"
  if ! helm dependency build --skip-refresh "$chart"; then
    warn "Cached Helm dependency resolution failed for ${chart}; refreshing repositories and retrying once"
    helm dependency build "$chart"
  fi
}

run_hook() {
  local hook="${ROOT}/.github/ci-local.sh"
  if [[ -f "$hook" ]]; then
    log "Repository-specific ${PHASE} hook"
    /opt/homebrew/bin/bash "$hook" "$PHASE"
  fi
}

phase_policy() {
  log "Checking required runner tools"
  local file tool
  local -a workflow_files=()
  for tool in git jq actionlint shellcheck hadolint gitleaks trivy syft docker helm kubeconform; do
    have "$tool" || die "Runner prerequisite is missing: $tool"
  done

  log "Checking patches, conflict markers, and workflow syntax"
  git show --check --format= HEAD
  if git grep -nE '^(<<<<<<< |>>>>>>> )|^=======$' -- ':!*.lock' ':!package-lock.json'; then
    die "Unresolved merge-conflict markers found"
  fi
  if [[ -d .github/workflows ]]; then
    while IFS= read -r file; do
      case "$file" in
        .github/workflows/*.yml|.github/workflows/*.yaml)
          [[ -f "$file" ]] && workflow_files+=("$file") ;;
      esac
    done < <(changed_files)
    if ((${#workflow_files[@]})); then
      actionlint -color -config-file "$ENGINE_ROOT/.github/actionlint.yaml" "${workflow_files[@]}"
    else
      log "No workflow files changed"
    fi
  fi

  log "Validating tracked JSON"
  while IFS= read -r file; do
    is_json_with_extensions "$file" && continue
    jq empty "$file" || die "Invalid JSON: $file"
  done < <(tracked_files '*.json' '*/**.json')

  {
    echo "# Universal CI inventory"
    echo
    echo "- Go modules: $(list_go_modules | sed '/^$/d' | wc -l | tr -d ' ')"
    echo "- Node projects: $(list_node_projects | sed '/^$/d' | wc -l | tr -d ' ')"
    echo "- Python projects: $(list_python_projects | sed '/^$/d' | wc -l | tr -d ' ')"
    echo "- Unity projects: $(list_unity_projects | sed '/^$/d' | wc -l | tr -d ' ')"
    echo "- Dockerfiles: $(list_dockerfiles | sed '/^$/d' | wc -l | tr -d ' ')"
    echo "- Helm charts selected: $(helm_chart_dirs | sed '/^$/d' | wc -l | tr -d ' ')"
  } | tee "$ARTIFACTS/inventory.md"
  summary "$(cat "$ARTIFACTS/inventory.md")"
}

phase_lint() {
  local dir files=() file editor

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    log "Go formatting and vet (${dir})"
    mapfile -t files < <(find "$dir" -type f -name '*.go' -not -path '*/vendor/*')
    if ((${#files[@]})); then
      local unformatted
      unformatted="$(gofmt -l "${files[@]}")"
      [[ -z "$unformatted" ]] || die "gofmt is required for: ${unformatted}"
    fi
    (cd "$dir" && go vet ./...)
    if have golangci-lint && [[ -f "$dir/.golangci.yml" || -f "$dir/.golangci.yaml" || -f "$dir/.golangci.toml" || -f "$dir/.golangci.json" ]]; then
      (cd "$dir" && golangci-lint run ./...)
    fi
  done < <(list_go_modules)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    log "Node dependency install (${dir})"
    npm_install "$dir"
    npm_run_if_present "$dir" check
    npm_run_if_present "$dir" lint
    npm_run_if_present "$dir" typecheck
    npm_run_if_present "$dir" format:check
  done < <(list_node_projects)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    local venv
    venv="$(python_venv "$dir")"
    if grep -Eq '^\[tool\.ruff' "$dir/pyproject.toml"; then
      log "Ruff lint and formatting (${dir})"
      (cd "$dir" && "$venv/bin/python" -m ruff check .)
      (cd "$dir" && "$venv/bin/python" -m ruff format --check .)
    else
      log "Python bytecode validation (${dir})"
      "$venv/bin/python" -m compileall -q "$dir"
    fi
  done < <(list_python_projects)

  mapfile -t files < <(tracked_files '*.sh' '*/**.sh')
  if ((${#files[@]})); then
    log "Shell syntax and static analysis (${#files[@]} files)"
    for file in "${files[@]}"; do bash -n "$file"; done
    shellcheck --severity=error -x "${files[@]}"
  fi

  mapfile -t files < <(list_dockerfiles)
  if ((${#files[@]})); then
    log "Dockerfile lint (${#files[@]} files)"
    hadolint --failure-threshold error "${files[@]}"
  fi

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    editor="$(unity_editor "$dir")"
    [[ -x "$editor" ]] || die "Pinned Unity editor is not installed: $editor"
    log "Unity project metadata (${dir})"
    "$PYTHON" - "$dir" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]) / "Assets"
missing = []
for path in root.rglob("*"):
    if path.name.endswith(".meta") or any(part.startswith(".") for part in path.parts):
        continue
    if not pathlib.Path(str(path) + ".meta").exists():
        missing.append(str(path))
if missing:
    raise SystemExit("Missing Unity .meta files:\n" + "\n".join(missing[:100]))
PY
  done < <(list_unity_projects)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    log "Helm lint (${dir})"
    build_helm_dependencies "$dir"
    helm lint --strict "$dir"
  done < <(helm_chart_dirs)

  run_hook
  summary "## Developer experience and lint\n\nAll detected first-party linters passed."
}

phase_test() {
  local dir venv editor result go_args
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    go_args=(-timeout=30m -covermode=atomic -coverprofile="$ARTIFACTS/go/$(echo "$dir" | tr '/.' '__').cover")
    if [[ "$FULL_SCAN" == "true" || "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
      go_args+=(-race)
      log "Go race tests (${dir})"
    else
      log "Go tests (${dir})"
    fi
    mkdir -p "$ARTIFACTS/go"
    (cd "$dir" && go test "${go_args[@]}" ./...)
  done < <(list_go_modules)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if npm_has_script "$dir" test; then
      npm_install "$dir"
      npm_run_if_present "$dir" test
    fi
  done < <(list_node_projects)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    venv="$(python_venv "$dir")"
    if [[ -d "$dir/tests" ]] || grep -q '\[tool.pytest' "$dir/pyproject.toml"; then
      log "Python tests (${dir})"
      (cd "$dir" && "$venv/bin/python" -m pytest)
    fi
  done < <(list_python_projects)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    editor="$(unity_editor "$dir")"
    result="$ARTIFACTS/unity-$(basename "$dir").xml"
    log "Unity EditMode tests (${dir})"
    "$editor" -batchmode -nographics -projectPath "$ROOT/$dir" -runTests -testPlatform EditMode -testResults "$result" -logFile -
  done < <(list_unity_projects)

  run_hook
  summary "## Tests\n\nAll detected unit, race, integration, and Unity EditMode test suites passed."
}

phase_security() {
  local dir venv gitleaks_args
  log "Secret detection"
  gitleaks_args=(git --redact --no-banner)
  [[ -f .gitleaks.toml ]] && gitleaks_args+=(--config=.gitleaks.toml)
  if [[ "$FULL_SCAN" == "true" || "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
    gitleaks "${gitleaks_args[@]}" --log-opts=HEAD .
  else
    gitleaks "${gitleaks_args[@]}" --log-opts=-1 .
  fi

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if have govulncheck; then
      log "Go vulnerability analysis (${dir})"
      (cd "$dir" && govulncheck ./...)
    fi
    if have gosec; then
      log "Go SAST (${dir})"
      (cd "$dir" && gosec -quiet -severity high -confidence high ./...)
    fi
  done < <(list_go_modules)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    npm_install "$dir"
    log "Production dependency audit (${dir})"
    npm_audit "$dir"
  done < <(list_node_projects)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    venv="$(python_venv "$dir")"
    log "Python dependency and source audit (${dir})"
    if [[ -f "$dir/requirements.lock" ]]; then
      "$venv/bin/python" -m pip_audit --strict --requirement "$dir/requirements.lock"
    elif [[ -f "$dir/requirements.txt" ]]; then
      "$venv/bin/python" -m pip_audit --strict --requirement "$dir/requirements.txt"
    fi
    if [[ -d "$dir/core" || -d "$dir/src" || -d "$dir/gittna" ]]; then
      local targets=() target config_args=()
      for target in core src scripts gittna; do
        [[ -d "$dir/$target" ]] && targets+=("$target")
      done
      [[ -f "$dir/pyproject.toml" ]] && config_args=(-c pyproject.toml)
      (cd "$dir" && "$venv/bin/python" -m bandit -q -r "${targets[@]}" "${config_args[@]}")
    fi
  done < <(list_python_projects)

  log "Critical vulnerability and configuration scan"
  trivy fs --scanners vuln,misconfig --severity CRITICAL --ignore-unfixed --exit-code 1 \
    --skip-dirs _universal-ci --skip-dirs .git --skip-dirs node_modules --skip-dirs .venv \
    --format json --output "$ARTIFACTS/trivy.json" .

  log "CycloneDX software bill of materials"
  syft scan dir:. --exclude './_universal-ci/**' --exclude './.git/**' \
    -o "cyclonedx-json=$ARTIFACTS/sbom.cdx.json"

  run_hook
  summary "## Security\n\nSecret detection, SAST, dependency audits, critical vulnerability scanning, and SBOM generation passed."
}

docker_tag_for() {
  local file="$1" slug
  slug="$(echo "$file" | tr '[:upper:]/._' '[:lower:]----' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  printf 'universal-ci:%s-%s-%s\n' "${GITHUB_REPOSITORY##*/}" "${GITHUB_SHA:-local}" "$slug"
}

phase_build() {
  local dir venv file tag context
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    log "Go build (${dir})"
    (cd "$dir" && go build ./...)
  done < <(list_go_modules)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if npm_has_script "$dir" build; then
      npm_install "$dir"
      npm_run_if_present "$dir" build
    fi
  done < <(list_node_projects)

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    venv="$(python_venv "$dir")"
    log "Python production compile (${dir})"
    "$venv/bin/python" -m compileall -q "$dir"
    if grep -q '^\[build-system\]' "$dir/pyproject.toml"; then
      (cd "$dir" && "$venv/bin/python" -m build --wheel --outdir "$ARTIFACTS/python")
    fi
  done < <(list_python_projects)

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    tag="$(docker_tag_for "$file")"
    context="."
    log "Container build (${file})"
    if ! docker build --pull --label "universal-ci.repo=${GITHUB_REPOSITORY:-local}" \
        --label "universal-ci.sha=${GITHUB_SHA:-local}" --tag "$tag" --file "$file" "$context"; then
      warn "BuildKit failed; retrying ${file} with Docker's noninteractive legacy builder"
      if ! env DOCKER_BUILDKIT=0 docker --config "$DOCKER_CONFIG" build --pull \
          --label "universal-ci.repo=${GITHUB_REPOSITORY:-local}" \
          --label "universal-ci.sha=${GITHUB_SHA:-local}" --tag "$tag" --file "$file" "$context"; then
        context="$(dirname "$file")"
        [[ "$context" != "." ]] || return 1
        warn "Retrying ${file} with its containing directory as build context"
        docker build --pull --label "universal-ci.repo=${GITHUB_REPOSITORY:-local}" \
          --label "universal-ci.sha=${GITHUB_SHA:-local}" --tag "$tag" --file "$(basename "$file")" "$context"
      fi
    fi
  done < <(list_dockerfiles)

  run_hook
  summary "## Build\n\nAll detected applications and production container images built successfully."
}

phase_readiness() {
  local compose env_args=() chart file tag image user health
  mkdir -p "$ARTIFACTS"

  while IFS= read -r compose; do
    [[ -n "$compose" ]] || continue
    log "Compose model validation (${compose})"
    if [[ -f .env.example ]]; then env_args=(--env-file .env.example); else env_args=(); fi
    docker compose "${env_args[@]}" -f "$compose" config --quiet
  done < <(tracked_files compose.yml compose.yaml docker-compose.yml docker-compose.yaml '*/compose.yml' '*/compose.yaml' '*/docker-compose.yml' '*/docker-compose.yaml')

  while IFS= read -r chart; do
    [[ -n "$chart" ]] || continue
    log "Production Helm render (${chart})"
    build_helm_dependencies "$chart"
    helm lint --strict "$chart"
    helm template universal-ci "$chart" > "$ARTIFACTS/$(echo "$chart" | tr '/' '_').yaml"
  done < <(helm_chart_dirs)

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    tag="$(docker_tag_for "$file")"
    if ! docker image inspect "$tag" >/dev/null 2>&1; then
      warn "Expected build image is missing and will be rebuilt: $tag"
      docker build --label "universal-ci.repo=${GITHUB_REPOSITORY:-local}" \
        --label "universal-ci.sha=${GITHUB_SHA:-local}" --tag "$tag" --file "$file" .
    fi
    image="$tag"
    user="$(docker image inspect --format '{{.Config.User}}' "$image")"
    health="$(docker image inspect --format '{{if .Config.Healthcheck}}configured{{else}}not-configured{{end}}' "$image")"
    printf '%s\tuser=%s\thealthcheck=%s\n' "$image" "${user:-root}" "$health" | tee -a "$ARTIFACTS/images.txt"
    if [[ -z "$user" || "$user" == "0" || "$user" == "root" ]]; then
      warn "Production image runs as root: $image"
    fi
    log "Critical runtime image scan (${image})"
    trivy image --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 \
      --format json --output "$ARTIFACTS/$(echo "$file" | tr '/.' '__')-trivy.json" "$image"
    docker image rm "$image" >/dev/null 2>&1 || true
  done < <(list_dockerfiles)

  if [[ -f Makefile ]] && grep -Eq '^validate-alerts:' Makefile; then
    log "Operational alert validation"
    make validate-alerts
  fi
  if [[ -f Makefile ]] && grep -Eq '^e2e:' Makefile; then
    log "End-to-end production smoke test"
    make e2e
  fi

  run_hook
  summary "## Production readiness\n\nDeployment models, runtime images, critical image vulnerabilities, operational rules, and available smoke tests passed."
}

case "$PHASE" in
  policy) phase_policy ;;
  lint) phase_lint ;;
  test) phase_test ;;
  security) phase_security ;;
  build) phase_build ;;
  readiness) phase_readiness ;;
  *) die "Usage: $0 {policy|lint|test|security|build|readiness}" ;;
esac
