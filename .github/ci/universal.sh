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
GO_COVERAGE_MIN="${UNIVERSAL_CI_GO_COVERAGE_MIN:-20}"

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
    _universal-ci/*|.ci-artifacts/*|.vib/*|vendor/*|third_party/*|node_modules/*|.venv/*|*/node_modules/*|*/.venv/*|testdata/*|*/testdata/*|examples/*|*/examples/*)
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
  tracked_files pyproject.toml requirements.txt requirements.lock '*/pyproject.toml' '*/requirements.txt' '*/requirements.lock' |
    sed -E 's#/(pyproject\.toml|requirements\.(txt|lock))$##; s#^(pyproject\.toml|requirements\.(txt|lock))$#.#' |
    sort -u
}

list_security_python_projects() {
  git ls-files pyproject.toml requirements.txt requirements.lock '*/pyproject.toml' '*/requirements.txt' '*/requirements.lock' |
    while IFS= read -r file; do
      case "$file" in
        vendor/*|third_party/*|.venv/*|*/.venv/*|testdata/*|*/testdata/*)
          continue ;;
      esac
      printf '%s\n' "$file"
    done |
    sed -E 's#/(pyproject\.toml|requirements\.(txt|lock))$##; s#^(pyproject\.toml|requirements\.(txt|lock))$#.#' |
    sort -u
}

list_unity_projects() {
  tracked_files '*/ProjectSettings/ProjectVersion.txt' | sed 's#/ProjectSettings/ProjectVersion.txt$##' | sort -u
}

list_dockerfiles() {
  tracked_files Dockerfile 'Dockerfile.*' '*/Dockerfile' '*/Dockerfile.*' '*/*/Dockerfile' '*/*/Dockerfile.*' |
    awk 'BEGIN { FS="/" } !/\.dockerignore$/ && (NF <= 2 || ($1 != "docker" && $1 != "bitnami"))' |
    sort -u
}

list_compose_files() {
  tracked_files compose.yml compose.yaml docker-compose.yml docker-compose.yaml \
    '*/compose.yml' '*/compose.yaml' '*/docker-compose.yml' '*/docker-compose.yaml'
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
    die "Node project ${dir} must commit a supported lockfile"
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

run_osv_gate() {
  local artifact_name="$1" scope="$2" rc=0
  local -a config_args=()
  shift 2
  [[ -f "$ROOT/osv-scanner.toml" ]] && config_args=(--config "$ROOT/osv-scanner.toml")
  osv-scanner scan source --no-resolve --no-call-analysis=go "${config_args[@]}" --format json \
    --output-file "$ARTIFACTS/${artifact_name}.json" "$@" \
    > "$ARTIFACTS/${artifact_name}.log" 2>&1 || rc=$?
  cat "$ARTIFACTS/${artifact_name}.log"
  ((rc <= 1)) || die "OSV-Scanner failed while scanning ${scope} (exit ${rc})"
  if ((rc == 1)); then
    jq -r '.results[]? | .source.path as $source | .packages[]? | .package as $package | .vulnerabilities[]? | "\(.id) \($package.name)@\($package.version) [\($source)]"' \
      "$ARTIFACTS/${artifact_name}.json" | sort -u
    die "OSV found known vulnerabilities in ${scope}"
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
  for tool in git jq actionlint shellcheck hadolint gitleaks trivy syft docker helm kubeconform govulncheck gosec staticcheck osv-scanner zizmor; do
    have "$tool" || die "Runner prerequisite is missing: $tool"
  done

  log "Checking patches, conflict markers, and workflow syntax"
  if [[ -n "$BASE_SHA" && "$BASE_SHA" != "0000000000000000000000000000000000000000" ]] && git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
    git diff --check "${BASE_SHA}...HEAD"
  else
    git show --check --format= HEAD
  fi
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

phase_shift_left() {
  local file slug rc findings dir
  local -a changed=() workflow_files=() iac_files=() dependency_dirs=() gitleaks_args=()

  while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] || continue
    case "$file" in
      go.mod|go.sum|package.json|package-lock.json|npm-shrinkwrap.json|pnpm-lock.yaml|yarn.lock|requirements.txt|requirements.lock|pyproject.toml|osv-scanner.toml|*/go.mod|*/go.sum|*/package.json|*/package-lock.json|*/npm-shrinkwrap.json|*/pnpm-lock.yaml|*/yarn.lock|*/requirements.txt|*/requirements.lock|*/pyproject.toml|*/osv-scanner.toml)
        dir="${file%/*}"
        [[ "$dir" == "$file" ]] && dir="."
        dependency_dirs+=("$dir") ;;
    esac
    case "$file" in
      .github/*|*package-lock.json|*pnpm-lock.yaml|*.lock)
        ;;
      Dockerfile|Dockerfile.*|*/Dockerfile|*/Dockerfile.*|*.tf|*.tf.json|*.tfvars|*.yaml|*.yml)
        iac_files+=("$file") ;;
    esac
    is_ignored_path "$file" && continue
    changed+=("$file")
    case "$file" in
      .github/workflows/*.yml|.github/workflows/*.yaml|.github/actions/*/action.yml|.github/actions/*/action.yaml)
        workflow_files+=("$file") ;;
    esac
  done < <(changed_files)
  printf '%s\n' "${changed[@]}" > "$ARTIFACTS/changed-files.txt"

  if ((${#dependency_dirs[@]})); then
    mapfile -t dependency_dirs < <(printf '%s\n' "${dependency_dirs[@]}" | sort -u)
    for dir in "${dependency_dirs[@]}"; do
      if [[ -f "$dir/package.json" && ! -f "$dir/package-lock.json" && ! -f "$dir/pnpm-lock.yaml" && ! -f "$dir/yarn.lock" && ! -f "$dir/npm-shrinkwrap.json" ]]; then
        die "Changed Node project ${dir} must commit a supported lockfile"
      fi
    done
    log "Scanning changed dependency manifests before build and test"
    run_osv_gate "changed-dependencies" "changed dependency manifests" "${dependency_dirs[@]}"
  fi

  log "Enforcing reproducible dependency inputs"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if [[ ! -f "$file/package-lock.json" && ! -f "$file/pnpm-lock.yaml" && ! -f "$file/yarn.lock" && ! -f "$file/npm-shrinkwrap.json" ]]; then
      die "Node project ${file} must commit package-lock.json, pnpm-lock.yaml, yarn.lock, or npm-shrinkwrap.json"
    fi
  done < <(list_node_projects)
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if grep -Eq '^[[:space:]]*require([[:space:](]|$)' "$file/go.mod" && [[ ! -f "$file/go.sum" ]]; then
      die "Go module ${file} declares dependencies but has no committed go.sum"
    fi
  done < <(list_go_modules)

  log "Rejecting oversized source additions"
  for file in "${changed[@]}"; do
    if (( $(wc -c < "$file") > ${UNIVERSAL_CI_MAX_FILE_BYTES:-5242880} )); then
      die "Changed file exceeds the 5 MiB source limit: ${file}"
    fi
  done

  if ((${#workflow_files[@]})); then
    log "Auditing changed GitHub automation and immutable action references"
    actionlint -color -config-file "$ENGINE_ROOT/.github/actionlint.yaml" "${workflow_files[@]}"
    "$PYTHON" - "${workflow_files[@]}" <<'PY'
import pathlib, re, sys

uses = re.compile(r"^\s*(?:-\s*)?uses:\s*['\"]?([^'\"\s#]+)")
bad = []
for name in sys.argv[1:]:
    for lineno, line in enumerate(pathlib.Path(name).read_text().splitlines(), 1):
        match = uses.match(line)
        if not match:
            continue
        target = match.group(1)
        if target.startswith("./"):
            continue
        if target.startswith("docker://"):
            if not re.search(r"@sha256:[0-9a-fA-F]{64}$", target):
                bad.append(f"{name}:{lineno}: container action must use an immutable sha256 digest: {target}")
            continue
        ref = target.rsplit("@", 1)[-1] if "@" in target else ""
        if not re.fullmatch(r"[0-9a-fA-F]{40}", ref):
            bad.append(f"{name}:{lineno}: action must be pinned to a full commit SHA: {target}")
if bad:
    raise SystemExit("\n".join(bad))
PY
    zizmor --min-severity medium --min-confidence medium --format github "${workflow_files[@]}" | tee "$ARTIFACTS/zizmor-changed.txt"
  else
    log "No automation files changed"
  fi
  if [[ -d .github ]]; then
    log "Recording the full GitHub automation posture"
    zizmor --no-exit-codes --min-severity informational --format sarif .github > "$ARTIFACTS/zizmor.sarif"
  fi

  log "Scanning the change for leaked credentials"
  gitleaks_args=(git --redact --no-banner)
  [[ -f .gitleaks.toml ]] && gitleaks_args+=(--config=.gitleaks.toml)
  if [[ -n "$BASE_SHA" && "$BASE_SHA" != "0000000000000000000000000000000000000000" ]] && git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
    gitleaks "${gitleaks_args[@]}" --log-opts="${BASE_SHA}...HEAD" .
  else
    gitleaks "${gitleaks_args[@]}" --log-opts=-1 .
  fi

  if ((${#iac_files[@]})); then
    log "Scanning changed infrastructure and deployment files"
    mkdir -p "$ARTIFACTS/trivy-config"
    for file in "${iac_files[@]}"; do
      slug="$(echo "$file" | tr '/.' '__' | tr -cd '[:alnum:]_-')"
      rc=0
      trivy config --severity HIGH,CRITICAL --exit-code 1 --format json \
        --output "$ARTIFACTS/trivy-config/${slug}.json" "$file" || rc=$?
      if ((rc != 0)); then
        jq -r '.Results[]? | .Target as $target | .Misconfigurations[]? | "\(.Severity) \(.ID) \($target): \(.Title)"' \
          "$ARTIFACTS/trivy-config/${slug}.json"
        die "High-severity infrastructure finding introduced in ${file}"
      fi
    done
  else
    log "No infrastructure files changed"
  fi

  findings=${#changed[@]}
  {
    echo "# Shift-left change gate"
    echo
    echo "- Changed first-party files reviewed: ${findings}"
    echo "- Changed automation files audited: ${#workflow_files[@]}"
    echo "- Changed dependency project roots scanned: ${#dependency_dirs[@]}"
    echo "- Changed infrastructure files scanned: ${#iac_files[@]}"
    echo "- Dependency inputs are reproducible"
    echo "- No new secrets or high-severity infrastructure findings"
  } | tee "$ARTIFACTS/shift-left.md"
  summary "$(cat "$ARTIFACTS/shift-left.md")"
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
    (cd "$dir" && staticcheck ./...)
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
  local dir venv editor result go_args cover log_file coverage slug
  mkdir -p "$ARTIFACTS/go"
  printf 'module\tcoverage_percent\tminimum_percent\n' > "$ARTIFACTS/go/coverage.tsv"
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    slug="$(echo "$dir" | tr '/.' '__')"
    cover="$ARTIFACTS/go/${slug}.cover"
    log_file="$ARTIFACTS/go/${slug}.log"
    go_args=(-timeout=30m -covermode=atomic -coverprofile="$cover")
    if [[ "$FULL_SCAN" == "true" || "${GITHUB_EVENT_NAME:-}" == "schedule" ]]; then
      go_args+=(-race)
      log "Go race tests (${dir})"
    else
      log "Go tests (${dir})"
    fi
    (cd "$dir" && go test "${go_args[@]}" ./...) | tee "$log_file"
    coverage="$(cd "$dir" && go tool cover -func="$cover" | awk '/^total:/ {gsub(/%/, "", $3); print $3}')"
    [[ -n "$coverage" ]] || die "Unable to calculate Go coverage for ${dir}"
    printf '%s\t%s\t%s\n' "$dir" "$coverage" "$GO_COVERAGE_MIN" | tee -a "$ARTIFACTS/go/coverage.tsv"
    awk -v actual="$coverage" -v minimum="$GO_COVERAGE_MIN" 'BEGIN { exit !(actual + 0 >= minimum + 0) }' ||
      die "Go coverage for ${dir} is ${coverage}%, below the ${GO_COVERAGE_MIN}% minimum"
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
      slug="$(echo "$dir" | tr '/.' '__')"
      (cd "$dir" && "$venv/bin/python" -m pytest --junitxml="$ARTIFACTS/python-${slug}.xml")
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
  local dir venv gitleaks_args slug config_count manifest_count
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
    slug="$(echo "$dir" | tr '/.' '__')"
    log "Go vulnerability analysis (${dir})"
    (cd "$dir" && govulncheck ./...)
    log "Go SAST (${dir})"
    (cd "$dir" && gosec -quiet -severity high -confidence high -fmt sarif \
      -out "$ARTIFACTS/gosec-${slug}.sarif" ./...)
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
    if [[ -d "$dir/core" || -d "$dir/src" || -d "$dir/gittna" || -f "$dir/main.py" ]]; then
      local targets=() target config_args=()
      for target in core src scripts gittna; do
        [[ -d "$dir/$target" ]] && targets+=("$target")
      done
      [[ -f "$dir/main.py" ]] && targets+=(main.py)
      [[ -f "$dir/pyproject.toml" ]] && config_args=(-c pyproject.toml)
      (cd "$dir" && "$venv/bin/python" -m bandit -q -r "${targets[@]}" "${config_args[@]}")
    fi
  done < <(list_security_python_projects)

  manifest_count="$(find . -type f \( -name go.mod -o -name package-lock.json -o -name pnpm-lock.yaml -o -name yarn.lock -o -name requirements.txt -o -name requirements.lock -o -name pyproject.toml \) \
    -not -path './.git/*' -not -path './.ci-artifacts/*' -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/testdata/*' | wc -l | tr -d ' ')"
  if ((manifest_count > 0)); then
    log "Cross-ecosystem OSV dependency analysis"
    run_osv_gate "osv" "the repository dependency graph" -r --allow-no-lockfiles \
      --experimental-exclude .git --experimental-exclude .ci-artifacts --experimental-exclude _universal-ci \
      --experimental-exclude vendor --experimental-exclude third_party \
      --experimental-exclude node_modules --experimental-exclude .venv --experimental-exclude testdata \
      .
  fi

  log "High and critical filesystem vulnerability scan"
  trivy fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    --skip-dirs _universal-ci --skip-dirs .ci-artifacts --skip-dirs .git \
    --skip-dirs vendor --skip-dirs third_party --skip-dirs node_modules --skip-dirs .venv \
    --skip-dirs testdata \
    --format json --output "$ARTIFACTS/trivy.json" .

  log "Repository-wide infrastructure and secret posture report"
  trivy fs --scanners misconfig,secret --severity HIGH,CRITICAL --exit-code 0 \
    --skip-dirs _universal-ci --skip-dirs .ci-artifacts --skip-dirs .git \
    --skip-dirs vendor --skip-dirs third_party --skip-dirs node_modules --skip-dirs .venv \
    --skip-dirs testdata \
    --format json --output "$ARTIFACTS/trivy-posture.json" .
  config_count="$(jq '[.Results[]? | .Misconfigurations[]?, .Secrets[]?] | length' "$ARTIFACTS/trivy-posture.json")"
  if ((config_count > 0)); then
    warn "Trivy recorded ${config_count} existing high/critical posture findings; new findings are blocked by the shift-left gate"
    if [[ "${UNIVERSAL_CI_ENFORCE_FULL_POSTURE:-false}" == "true" ]]; then
      die "Repository-wide posture enforcement found ${config_count} high/critical findings"
    fi
  fi

  log "CycloneDX software bill of materials"
  syft scan dir:. --exclude './_universal-ci/**' --exclude './.ci-artifacts/**' --exclude './.git/**' \
    -o "cyclonedx-json=$ARTIFACTS/sbom.cdx.json"
  jq empty "$ARTIFACTS/sbom.cdx.json"
  shasum -a 256 "$ARTIFACTS/sbom.cdx.json" > "$ARTIFACTS/sbom.cdx.json.sha256"

  run_hook
  summary "## Security\n\nSecret detection, SAST, dependency audits, critical vulnerability scanning, and SBOM generation passed."
}

docker_tag_for() {
  local file="$1" slug
  slug="$(echo "$file" | tr '[:upper:]/._' '[:lower:]----' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  printf 'universal-ci:%s-%s-%s\n' "${GITHUB_REPOSITORY##*/}" "${GITHUB_SHA:-local}" "$slug"
}

compose_build_specs() {
  local compose
  local -a env_args=()
  while IFS= read -r compose; do
    [[ -n "$compose" ]] || continue
    if [[ -f .env.example ]]; then env_args=(--env-file .env.example); else env_args=(); fi
    docker compose "${env_args[@]}" -f "$compose" config --format json |
      jq -r '.services[]? | select(.build != null and (.build.target // "") != "") |
        [.build.context, (.build.dockerfile // "Dockerfile"), .build.target] | @tsv'
  done < <(list_compose_files)
}

compose_tag_for() {
  local context="$1" file="$2" target="$3" source slug
  case "$context" in
    "$ROOT") source="${file}-${target}" ;;
    "$ROOT"/*) source="${context#"$ROOT"/}/${file}-${target}" ;;
    *) source="$(basename "$context")/${file}-${target}" ;;
  esac
  slug="$(echo "$source" | tr '[:upper:]/._' '[:lower:]----' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  printf 'universal-ci:%s-%s-compose-%s\n' "${GITHUB_REPOSITORY##*/}" "${GITHUB_SHA:-local}" "$slug"
}

phase_build() {
  local dir venv file tag context target dockerfile_path
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

  while IFS=$'\t' read -r context file target; do
    [[ -n "$context" && -n "$file" && -n "$target" ]] || continue
    if [[ "$file" == /* ]]; then dockerfile_path="$file"; else dockerfile_path="$context/$file"; fi
    [[ -f "$dockerfile_path" ]] || die "Compose target Dockerfile does not exist: $dockerfile_path"
    tag="$(compose_tag_for "$context" "$file" "$target")"
    log "Compose production target build (${file} target=${target})"
    docker build --pull --label "universal-ci.repo=${GITHUB_REPOSITORY:-local}" \
      --label "universal-ci.sha=${GITHUB_SHA:-local}" --tag "$tag" --target "$target" \
      --file "$dockerfile_path" "$context"
  done < <(compose_build_specs | sort -u)

  run_hook
  summary "## Build\n\nAll detected applications and production container images built successfully."
}

phase_readiness() {
  local compose env_args=() chart file tag image user health context target dockerfile_path evidence
  mkdir -p "$ARTIFACTS"

  while IFS= read -r compose; do
    [[ -n "$compose" ]] || continue
    log "Compose model validation (${compose})"
    if [[ -f .env.example ]]; then env_args=(--env-file .env.example); else env_args=(); fi
    docker compose "${env_args[@]}" -f "$compose" config --quiet
  done < <(list_compose_files)

  while IFS= read -r chart; do
    [[ -n "$chart" ]] || continue
    log "Production Helm render (${chart})"
    build_helm_dependencies "$chart"
    helm lint --strict "$chart"
    file="$ARTIFACTS/$(echo "$chart" | tr '/' '_').yaml"
    helm template universal-ci "$chart" > "$file"
    kubeconform -strict -summary -ignore-missing-schemas "$file"
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
    log "High and critical runtime image scan (${image})"
    trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
      --format json --output "$ARTIFACTS/$(echo "$file" | tr '/.' '__')-trivy.json" "$image"
    docker image rm "$image" >/dev/null 2>&1 || true
  done < <(list_dockerfiles)

  while IFS=$'\t' read -r context file target; do
    [[ -n "$context" && -n "$file" && -n "$target" ]] || continue
    if [[ "$file" == /* ]]; then dockerfile_path="$file"; else dockerfile_path="$context/$file"; fi
    tag="$(compose_tag_for "$context" "$file" "$target")"
    if ! docker image inspect "$tag" >/dev/null 2>&1; then
      warn "Expected Compose target image is missing and will be rebuilt: $tag"
      docker build --label "universal-ci.repo=${GITHUB_REPOSITORY:-local}" \
        --label "universal-ci.sha=${GITHUB_SHA:-local}" --tag "$tag" --target "$target" \
        --file "$dockerfile_path" "$context"
    fi
    image="$tag"
    user="$(docker image inspect --format '{{.Config.User}}' "$image")"
    health="$(docker image inspect --format '{{if .Config.Healthcheck}}configured{{else}}not-configured{{end}}' "$image")"
    printf '%s\tuser=%s\thealthcheck=%s\n' "$image" "${user:-root}" "$health" | tee -a "$ARTIFACTS/images.txt"
    if [[ -z "$user" || "$user" == "0" || "$user" == "root" ]]; then
      warn "Production Compose target runs as root: $image"
    fi
    log "High and critical Compose target image scan (${image})"
    evidence="compose-$(echo "${file}-${target}" | tr '/.' '__')-trivy.json"
    trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
      --format json --output "$ARTIFACTS/$evidence" "$image"
    docker image rm "$image" >/dev/null 2>&1 || true
  done < <(compose_build_specs | sort -u)

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
  shift-left) phase_shift_left ;;
  lint) phase_lint ;;
  test) phase_test ;;
  security) phase_security ;;
  build) phase_build ;;
  readiness) phase_readiness ;;
  *) die "Usage: $0 {policy|lint|test|security|build|readiness}" ;;
esac
