#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Patch kserve-controller to use the odh-stable image tag
#
# This script:
# 1. Sets up the PVC and CSV patch (one-time setup, skipped if already done)
# 2. Copies the existing kserve manifests from the operator pod to a temp dir
# 3. Patches all kserve-controller image references to :odh-stable
# 4. Copies the patched manifests back to the operator pod
# 5. Restarts the operator to apply the change
#
# Prerequisites:
# - oc CLI logged into your OpenShift cluster with cluster-admin privileges
#
# Usage:
#   ./setup-kserve-odh-stable.sh                  # Full setup
#   ./setup-kserve-odh-stable.sh --skip-setup      # Skip PVC/CSV setup (if already done)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
KSERVE_IMAGE="quay.io/opendatahub/kserve-controller:odh-stable"
KSERVE_IMAGE_ORIGINAL="quay.io/opendatahub/kserve-controller:latest"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"
KSERVE_NAMESPACE="${KSERVE_NAMESPACE:-opendatahub}"
SKIP_SETUP="${SKIP_SETUP:-false}"
RESET="${RESET:-false}"

# PVC and manifest mount path for kserve inside the operator pod
PVC_NAME="kserve-manifests"
MANIFEST_MOUNT="/opt/manifests/kserve"

# Temporary directory for downloaded/patched manifests
TEMP_DIR="${SCRIPT_DIR}/.kserve-setup-temp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-setup)
                SKIP_SETUP="true"
                shift
                ;;
            --reset)
                RESET="true"
                SKIP_SETUP="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Patch the kserve-controller deployment to use:
  ${KSERVE_IMAGE}

This is done by overriding the operator's kserve manifests via a PVC mount,
so the change persists through operator reconciliation.

Options:
    --skip-setup    Skip the one-time PVC and CSV patch setup
    --reset         Restore the original manifests from the operator image
                    (resets kserve-controller back to :latest)
    --help, -h      Show this help message

Environment Variables:
    OPERATOR_NAMESPACE    Operator namespace (default: openshift-operators)
    KSERVE_NAMESPACE      Namespace where kserve-controller-manager runs (default: opendatahub)
    SKIP_SETUP            Skip PVC/CSV setup (default: false)

Examples:
    $(basename "$0")               # Full setup (patch to :odh-stable)
    $(basename "$0") --skip-setup  # Re-patch without PVC/CSV setup
    $(basename "$0") --reset       # Restore original :latest image
EOF
}

# Check for required tools
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v oc &> /dev/null; then
        log_error "oc CLI is required but not installed. Aborting."
        exit 1
    fi

    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please run 'oc login' first."
        exit 1
    fi

    log_info "Prerequisites check passed."
    log_info "Logged in as: $(oc whoami)"
    log_info "Cluster: $(oc whoami --show-server)"
}

# Apply PVC for kserve manifest storage
apply_pvc() {
    log_info "Checking if PVC '${PVC_NAME}' already exists..."

    if oc get pvc -n "${OPERATOR_NAMESPACE}" "${PVC_NAME}" &> /dev/null; then
        log_info "PVC '${PVC_NAME}' already exists. Skipping PVC creation."
        return 0
    fi

    log_info "Creating PVC '${PVC_NAME}' in ${OPERATOR_NAMESPACE}..."

    cat <<EOF | oc apply -n "${OPERATOR_NAMESPACE}" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

    log_info "PVC created successfully."
}

# Patch the CSV to mount the PVC at the kserve manifest path
patch_csv() {
    log_info "Finding ODH operator CSV..."

    local csv
    csv=$(oc get csv -n "${OPERATOR_NAMESPACE}" -o name | grep opendatahub-operator | head -n1 | cut -d/ -f2)

    if [[ -z "$csv" ]]; then
        log_error "Could not find opendatahub-operator CSV in ${OPERATOR_NAMESPACE}"
        exit 1
    fi

    log_info "Found CSV: ${csv}"

    # Check if CSV is already patched for kserve
    local volume_mounts
    volume_mounts=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.install.spec.deployments[0].spec.template.spec.containers[0].volumeMounts}' \
        2>/dev/null || echo "")

    if echo "${volume_mounts}" | grep -q "${PVC_NAME}"; then
        log_info "CSV already patched for kserve. Skipping CSV patch."
        return 0
    fi

    log_info "Patching CSV ${csv} to mount PVC at ${MANIFEST_MOUNT}..."

    local patch
    patch=$(cat <<EOF
[
  {
    "op": "replace",
    "path": "/spec/install/spec/deployments/0/spec/replicas",
    "value": 1
  },
  {
    "op": "replace",
    "path": "/spec/install/spec/deployments/0/spec/strategy",
    "value": {"type": "Recreate"}
  },
  {
    "op": "add",
    "path": "/spec/install/spec/deployments/0/spec/template/spec/securityContext",
    "value": {"fsGroup": 1000}
  },
  {
    "op": "add",
    "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "${PVC_NAME}",
      "mountPath": "${MANIFEST_MOUNT}"
    }
  },
  {
    "op": "add",
    "path": "/spec/install/spec/deployments/0/spec/template/spec/volumes/-",
    "value": {
      "name": "${PVC_NAME}",
      "persistentVolumeClaim": {
        "claimName": "${PVC_NAME}"
      }
    }
  }
]
EOF
)

    if ! oc patch csv "${csv}" -n "${OPERATOR_NAMESPACE}" --type json --patch "${patch}"; then
        log_warn "CSV patch may have already been applied or failed. Continuing..."
    else
        log_info "CSV patched successfully."
    fi
}

# Wait for operator pod to be ready
wait_for_operator_pod() {
    local max_attempts="${1:-60}"
    local attempt=0

    log_info "Waiting for operator pod to be ready..."

    sleep 10

    while [[ $attempt -lt $max_attempts ]]; do
        local pod_count
        pod_count=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l name=opendatahub-operator --no-headers 2>/dev/null | wc -l || echo "0")

        if [[ "$pod_count" -eq 0 ]]; then
            log_info "No operator pod found yet... (attempt $((attempt + 1))/$max_attempts)"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        local terminating
        terminating=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l name=opendatahub-operator \
            -o jsonpath='{.items[*].metadata.deletionTimestamp}' 2>/dev/null || echo "")

        if [[ -n "$terminating" ]]; then
            log_info "Operator pod is terminating, waiting... (attempt $((attempt + 1))/$max_attempts)"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        local pod_status
        pod_status=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l name=opendatahub-operator \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

        if [[ "$pod_status" == "Running" ]]; then
            local ready
            ready=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l name=opendatahub-operator \
                -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [[ "$ready" == "True" ]]; then
                log_info "Operator pod is ready."
                return 0
            fi
        fi

        log_info "Pod status: ${pod_status:-unknown}... (attempt $((attempt + 1))/$max_attempts)"
        sleep 5
        attempt=$((attempt + 1))
    done

    log_warn "Operator pod did not become ready in time, but continuing anyway..."
    return 0
}

# Perform one-time setup (PVC and CSV patch)
perform_one_time_setup() {
    log_step "Performing one-time setup (PVC and CSV patch)..."

    apply_pvc
    patch_csv

    # Wait for operator pod to restart after CSV patch
    wait_for_operator_pod 60

    log_info "One-time setup complete."
}

# Get the operator pod name
get_operator_pod() {
    local pod
    pod=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l name=opendatahub-operator \
        -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")

    if [[ -z "$pod" ]]; then
        log_error "Could not find opendatahub-operator pod in ${OPERATOR_NAMESPACE}"
        exit 1
    fi

    echo "$pod"
}

# Extract kserve manifests from the operator image (bypasses the empty PVC mount)
extract_manifests_from_image() {
    local local_manifests="$1"
    local op_pod
    op_pod=$(get_operator_pod)

    # Determine the operator image from the running pod
    local operator_image
    operator_image=$(oc get pod "${op_pod}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.containers[?(@.name=="manager")].image}' 2>/dev/null || echo "")

    if [[ -z "$operator_image" ]]; then
        log_error "Could not determine operator image from pod ${op_pod}"
        exit 1
    fi

    log_info "Operator image: ${operator_image}"
    log_info "Extracting kserve manifests from operator image (path: ${MANIFEST_MOUNT}) ..."

    # oc image extract pulls directly from the registry, bypassing the PVC that shadows
    # the same path inside the running container.
    if ! oc image extract "${operator_image}" \
            --path "${MANIFEST_MOUNT}/:${local_manifests}/" \
            --confirm; then
        log_error "Failed to extract manifests from operator image."
        log_error "Ensure the image is pullable and 'oc image extract' has registry credentials."
        exit 1
    fi

    local file_count
    file_count=$(find "${local_manifests}" -type f | wc -l | tr -d ' ')
    log_info "Extracted ${file_count} file(s) from the operator image."
}

# Copy kserve manifests from the operator image, patch the image reference, copy back
patch_kserve_manifests() {
    local op_pod
    op_pod=$(get_operator_pod)
    log_info "Using operator pod: ${op_pod}"

    log_info "Waiting for operator pod to be ready..."
    if ! oc wait pod/"${op_pod}" -n "${OPERATOR_NAMESPACE}" --for=condition=Ready --timeout=60s; then
        log_error "Operator pod did not become ready in time"
        exit 1
    fi

    local local_manifests="${TEMP_DIR}/kserve-manifests"
    mkdir -p "${local_manifests}"

    # The PVC we mounted is empty (fresh filesystem), so we cannot oc cp FROM the pod at
    # MANIFEST_MOUNT — we'd only get lost+found.  Instead, pull the manifests directly out
    # of the operator image layers, which still contain the original content.
    extract_manifests_from_image "${local_manifests}"

    # Patch every YAML/JSON file that references a kserve-controller image
    log_info "Patching kserve-controller image to: ${KSERVE_IMAGE}"

    local patched=0
    while IFS= read -r -d '' file; do
        if grep -q 'kserve-controller' "${file}"; then
            # Replace any tag on the quay.io/opendatahub/kserve-controller image.
            # The pattern matches a bare URL so it works for both:
            #   image: quay.io/opendatahub/kserve-controller:latest   (YAML)
            #   kserve-controller=quay.io/opendatahub/kserve-controller:latest  (params.env)
            sed -i.bak \
                "s|quay\.io/opendatahub/kserve-controller:[^[:space:]\"']*|${KSERVE_IMAGE}|g" \
                "${file}" \
                && rm -f "${file}.bak"
            log_info "  Patched: ${file#"${local_manifests}/"}"
            patched=$((patched + 1))
        fi
    done < <(find "${local_manifests}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.env' \) -print0)

    if [[ $patched -eq 0 ]]; then
        log_warn "No manifest files containing 'kserve-controller' were found in ${MANIFEST_MOUNT}."
        log_warn "The kserve-controller image reference may use a different path inside the operator image."
        log_warn "List what was extracted:"
        find "${local_manifests}" -type f | sed "s|${local_manifests}/||" | sort
    else
        log_info "Patched ${patched} file(s)."
    fi

    # Copy back using oc cp, the same way setup-odh-main.sh does.
    # This is safe because our local_manifests dir came from oc image extract,
    # so it has no lost+found — that directory only appears when copying FROM the
    # live pod where the empty PVC is mounted.
    # oc cp handles the extraction via the oc binary itself and does not require
    # tar to be present in the (minimal/distroless) operator container.
    log_info "Copying patched manifests into pod ${op_pod}:${MANIFEST_MOUNT} ..."
    if ! oc cp "${local_manifests}/." "${OPERATOR_NAMESPACE}/${op_pod}:${MANIFEST_MOUNT}" -c manager; then
        log_error "Failed to copy manifests to operator pod"
        exit 1
    fi

    log_info "Manifests copied successfully."
}

# Restore original manifests from the operator image (no patching)
restore_kserve_manifests() {
    local op_pod
    op_pod=$(get_operator_pod)
    log_info "Using operator pod: ${op_pod}"

    log_info "Waiting for operator pod to be ready..."
    if ! oc wait pod/"${op_pod}" -n "${OPERATOR_NAMESPACE}" --for=condition=Ready --timeout=60s; then
        log_error "Operator pod did not become ready in time"
        exit 1
    fi

    local local_manifests="${TEMP_DIR}/kserve-manifests"
    mkdir -p "${local_manifests}"

    extract_manifests_from_image "${local_manifests}"

    log_info "Copying original (unpatched) manifests into pod ${op_pod}:${MANIFEST_MOUNT} ..."
    if ! oc cp "${local_manifests}/." "${OPERATOR_NAMESPACE}/${op_pod}:${MANIFEST_MOUNT}" -c manager; then
        log_error "Failed to copy manifests to operator pod"
        exit 1
    fi

    log_info "Original manifests restored."
}

# Restart the operator deployment
restart_operator() {
    log_info "Restarting operator deployment..."

    oc rollout restart deploy -n "${OPERATOR_NAMESPACE}" -l name=opendatahub-operator

    log_info "Waiting for operator rollout to complete..."
    if ! oc rollout status deploy -n "${OPERATOR_NAMESPACE}" -l name=opendatahub-operator --timeout=120s; then
        log_warn "Operator rollout may still be in progress"
    fi

    log_info "Operator restarted."
}

# Wait for kserve-controller-manager to reflect the expected image, then print a summary
verify() {
    local expected_image="${KSERVE_IMAGE}"
    local max_attempts=60   # 60 × 5 s = 5 minutes
    local attempt=0

    log_info "Waiting for kserve-controller-manager to update to: ${expected_image}"

    while [[ $attempt -lt $max_attempts ]]; do
        if ! oc get deploy kserve-controller-manager -n "${KSERVE_NAMESPACE}" &> /dev/null; then
            log_info "kserve-controller-manager not found yet in '${KSERVE_NAMESPACE}', waiting... (attempt $((attempt + 1))/$max_attempts)"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        local current_image
        current_image=$(oc get deploy kserve-controller-manager -n "${KSERVE_NAMESPACE}" \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

        if [[ "$current_image" == "$expected_image" ]]; then
            log_info "Image updated. Waiting for rollout to complete..."
            oc rollout status deploy/kserve-controller-manager -n "${KSERVE_NAMESPACE}" --timeout=120s \
                || log_warn "Rollout status timed out, but image is set correctly."
            break
        fi

        log_info "Current: ${current_image:-<not set>} — waiting for reconciliation... (attempt $((attempt + 1))/$max_attempts)"
        sleep 5
        attempt=$((attempt + 1))
    done

    echo ""
    echo "=============================================="
    echo "kserve-controller Image Summary"
    echo "=============================================="
    echo ""

    if oc get deploy kserve-controller-manager -n "${KSERVE_NAMESPACE}" &> /dev/null; then
        local final_image
        final_image=$(oc get deploy kserve-controller-manager -n "${KSERVE_NAMESPACE}" \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
        echo "  Namespace:      ${KSERVE_NAMESPACE}"
        echo "  Current image:  ${final_image}"
        echo "  Expected image: ${expected_image}"

        if [[ "$final_image" == "$expected_image" ]]; then
            echo ""
            log_info "Image matches. Patch applied successfully."
        else
            echo ""
            log_warn "Image did not update within the timeout. The operator may still be reconciling."
            log_warn "Re-check with:"
            log_warn "  oc get deploy kserve-controller-manager -n ${KSERVE_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].image}'"
        fi
    else
        log_warn "kserve-controller-manager not found in namespace '${KSERVE_NAMESPACE}'."
        log_warn "If your kserve namespace differs, set: KSERVE_NAMESPACE=<ns> $(basename "$0")"
    fi

    echo ""
    echo "=============================================="
}

# Cleanup temporary files
cleanup() {
    if [[ -d "${TEMP_DIR}" ]]; then
        log_info "Cleaning up temporary files..."
        rm -rf "${TEMP_DIR}"
    fi
}

# Main function
main() {
    parse_args "$@"

    if [[ "${RESET}" == "true" ]]; then
        echo "=============================================="
        echo "kserve-controller Image Reset (→ :latest)"
        echo "=============================================="
        echo ""
        echo "Configuration:"
        echo "  Restoring to:       ${KSERVE_IMAGE_ORIGINAL}"
        echo "  Operator namespace: ${OPERATOR_NAMESPACE}"
        echo "  kserve namespace:   ${KSERVE_NAMESPACE}"
        echo "  Manifest mount:     ${MANIFEST_MOUNT}"
        echo ""

        check_prerequisites
        mkdir -p "${TEMP_DIR}"
        trap cleanup EXIT

        echo ""
        log_step "Step 1/2: Restoring original manifests from operator image..."
        restore_kserve_manifests

        echo ""
        log_step "Step 2/2: Restarting operator..."
        restart_operator

        echo ""
        KSERVE_IMAGE="${KSERVE_IMAGE_ORIGINAL}" verify

        echo ""
        log_info "Done! kserve-controller has been reset to ${KSERVE_IMAGE_ORIGINAL}"
        echo ""
        return
    fi

    echo "=============================================="
    echo "kserve-controller odh-stable Image Patch"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  Target image:       ${KSERVE_IMAGE}"
    echo "  Operator namespace: ${OPERATOR_NAMESPACE}"
    echo "  kserve namespace:   ${KSERVE_NAMESPACE}"
    echo "  PVC name:           ${PVC_NAME}"
    echo "  Manifest mount:     ${MANIFEST_MOUNT}"
    echo "  Skip setup:         ${SKIP_SETUP}"
    echo ""

    check_prerequisites

    mkdir -p "${TEMP_DIR}"
    trap cleanup EXIT

    if [[ "${SKIP_SETUP}" != "true" ]]; then
        echo ""
        log_step "Step 1/3: Performing one-time PVC and CSV patch setup..."
        perform_one_time_setup
    else
        log_info "Skipping one-time setup (--skip-setup flag provided)"
    fi

    echo ""
    log_step "Step 2/3: Patching kserve manifests..."
    patch_kserve_manifests

    echo ""
    log_step "Step 3/3: Restarting operator..."
    restart_operator

    echo ""
    verify

    echo ""
    log_info "Done!"
    echo ""
    echo "To verify the running image:"
    echo "  oc get deploy kserve-controller-manager -n ${KSERVE_NAMESPACE} -o wide"
    echo ""
    echo "To re-patch after an operator upgrade (setup already done):"
    echo "  $(basename "$0") --skip-setup"
    echo ""
    echo "To restore the original :latest image:"
    echo "  $(basename "$0") --reset"
    echo ""
}

main "$@"
