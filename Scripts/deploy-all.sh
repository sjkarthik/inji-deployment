
#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Technoforte Inji Stack - Automated Deployment
# Modules: Certify, Mimoto, Web Wallet, Verify
# ==========================================================

ENVIRONMENT="${1:-dev}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${ROOT_DIR}/repositories"
VALUES_DIR="${ROOT_DIR}/values"

CONFIG="${ROOT_DIR}/config/environments/${ENVIRONMENT}.env"

if [[ ! -f "$CONFIG" ]]; then
    echo "ERROR: Environment configuration not found: $CONFIG"
    exit 1
fi

source "$CONFIG"

log() {
    echo "[$(date '+%F %T')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

command -v kubectl >/dev/null || fail "kubectl missing"
command -v helm >/dev/null || fail "helm missing"
command -v git >/dev/null || fail "git missing"

kubectl cluster-info >/dev/null || fail "Kubernetes unavailable"

mkdir -p "$REPO_DIR" "$VALUES_DIR"

clone_repo() {
    local name="$1"
    local url="$2"
    local ref="$3"

    if [[ ! -d "${REPO_DIR}/${name}/.git" ]]; then
        log "Cloning ${name}"
        git clone --depth 1 --branch "$ref" \
            "$url" "${REPO_DIR}/${name}"
    else
        log "${name} already cloned"
    fi
}

deploy_helm() {
    local name="$1"
    local chart="$2"
    local namespace="$3"
    local values="$4"

    [[ -d "$chart" ]] || fail "Chart missing: $chart"
    [[ -f "$values" ]] || fail "Values missing: $values"

    log "Deploying ${name} into ${namespace}"

    helm upgrade --install "$name" "$chart" \
        --namespace "$namespace" \
        --create-namespace \
        --values "$values" \
        --wait \
        --timeout 15m

    log "${name} deployment completed"
}

verify_namespace() {
    local namespace="$1"

    log "Checking namespace: ${namespace}"

    kubectl get deployments -n "$namespace"

    kubectl wait \
        --for=condition=Available \
        deployment --all \
        -n "$namespace" \
        --timeout=300s

    kubectl get pods -n "$namespace"
}

rollback_certify() {
    log "Rolling back Certify deployment"

    kubectl rollout undo deployment/inji-certify \
        -n "$CERTIFY_NAMESPACE" || true
}

# ----------------------------------------------------------
# STEP 1: Clone official repositories
# ----------------------------------------------------------

log "STEP 1: Cloning Inji repositories"

clone_repo inji-certify \
    https://github.com/inji/inji-certify.git "$CERTIFY_REF"

clone_repo mimoto \
    https://github.com/inji/mimoto.git "$MIMOTO_REF"

clone_repo inji-web \
    https://github.com/inji/inji-web.git "$WEB_REF"

clone_repo inji-verify \
    https://github.com/inji/inji-verify.git "$VERIFY_REF"

# ----------------------------------------------------------
# STEP 2: Verify supporting infrastructure
# ----------------------------------------------------------

log "STEP 2: Checking supporting services"

for namespace in "${DEPENDENCY_NAMESPACES[@]}"; do
    kubectl get namespace "$namespace" >/dev/null \
        || fail "Required namespace missing: $namespace"
done

# ----------------------------------------------------------
# STEP 3: Deploy Certify
# ----------------------------------------------------------

log "STEP 3: Deploying Inji Certify"

if [[ "$CERTIFY_MODE" == "image-only" ]]; then

    [[ -n "${CERTIFY_IMAGE:-}" ]] || fail "CERTIFY_IMAGE missing"

    kubectl set image \
        deployment/inji-certify \
        inji-certify="$CERTIFY_IMAGE" \
        -n "$CERTIFY_NAMESPACE"

    if ! kubectl rollout status \
        deployment/inji-certify \
        -n "$CERTIFY_NAMESPACE" \
        --timeout=600s; then
        rollback_certify
        fail "Certify rollout failed"
    fi

else
    deploy_helm inji-certify \
        "${REPO_DIR}/inji-certify/helm/inji-certify" \
        "$CERTIFY_NAMESPACE" \
        "${VALUES_DIR}/certify-values.yaml"
fi

# ----------------------------------------------------------
# STEP 4: Deploy Mimoto
# ----------------------------------------------------------

log "STEP 4: Deploying Mimoto"

deploy_helm mimoto \
    "${REPO_DIR}/mimoto/helm/mimoto" \
    "$MIMOTO_NAMESPACE" \
    "${VALUES_DIR}/mimoto-values.yaml"

verify_namespace "$MIMOTO_NAMESPACE"

# ----------------------------------------------------------
# STEP 5: Deploy Inji Web Wallet
# ----------------------------------------------------------

log "STEP 5: Deploying Inji Web Wallet"

deploy_helm inji-web \
    "${REPO_DIR}/inji-web/helm/inji-web" \
    "$WEB_NAMESPACE" \
    "${VALUES_DIR}/web-values.yaml"

verify_namespace "$WEB_NAMESPACE"

# ----------------------------------------------------------
# STEP 6: Deploy Inji Verify
# ----------------------------------------------------------

log "STEP 6: Deploying Inji Verify"

deploy_helm inji-verify \
    "${REPO_DIR}/inji-verify/helm/inji-verify" \
    "$VERIFY_NAMESPACE" \
    "${VALUES_DIR}/verify-values.yaml"

verify_namespace "$VERIFY_NAMESPACE"

# ----------------------------------------------------------
# STEP 7: Final status
# ----------------------------------------------------------

log "STEP 7: Final deployment verification"

for namespace in \
    "$CERTIFY_NAMESPACE" \
    "$MIMOTO_NAMESPACE" \
    "$WEB_NAMESPACE" \
    "$VERIFY_NAMESPACE"
do
    echo
    echo "========== ${namespace} =========="
    kubectl get pods -n "$namespace"
    kubectl get services -n "$namespace"
done

log "=========================================="
log "INJI STACK DEPLOYMENT COMPLETED"
log "Environment: ${ENVIRONMENT}"
log "=========================================="
