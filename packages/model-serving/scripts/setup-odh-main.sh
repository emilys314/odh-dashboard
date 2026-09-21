#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Setup script for updating ODH Dashboard to use the main image
#
# This script:
# 1. Sets up the PVC and CSV patch (one-time setup, skipped if already done)
# 2. Updates the distribution image parameter with the desired image
# 3. Copies the manifests to the operator pod
# 4. Restarts the operator to apply the new image
#
# Prerequisites:
# - oc CLI logged into your OpenShift cluster with cluster-admin privileges
# - curl for downloading files from GitHub
#
# Usage:
#   ./setup-odh-main.sh                    # Uses main image
#   ./setup-odh-main.sh pr-5476            # Uses a specific PR image
#   ./setup-odh-main.sh v2.38.2-odh        # Uses a specific version
#   ./setup-odh-main.sh sha256:abc123...   # Uses a specific image digest
#   ./setup-odh-main.sh --skip-setup       # Skip PVC/CSV setup (if already done)
#   ./setup-odh-main.sh --skip-setup main  # Skip setup and use main image
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../../../manifests" && pwd)"

# Configuration
DASHBOARD_IMAGE_TAG="${DASHBOARD_IMAGE_TAG:-main}"
DASHBOARD_IMAGE_REPO="${DASHBOARD_IMAGE_REPO:-quay.io/opendatahub/odh-dashboard}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"
DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-opendatahub}"
DASHBOARD_DEPLOYMENT_NAME="${DASHBOARD_DEPLOYMENT_NAME:-odh-dashboard}"
OPERATOR_NAME="${OPERATOR_NAME:-opendatahub-operator}"
SKIP_SETUP="${SKIP_SETUP:-false}"

# RHOAI namespace/operator values used when the ODH values are not available.
FALLBACK_OPERATOR_NAMESPACE="redhat-ods-operator"
FALLBACK_DASHBOARD_NAMESPACE="redhat-ods-applications"
FALLBACK_DASHBOARD_DEPLOYMENT_NAME="rhods-dashboard"
FALLBACK_OPERATOR_NAME="rhods-operator"

# GitHub URLs for setup files
CSV_PATCH_URL="https://raw.githubusercontent.com/opendatahub-io/opendatahub-operator/main/hack/component-dev/csv-patch.json"
PVC_URL="https://raw.githubusercontent.com/opendatahub-io/opendatahub-operator/main/hack/component-dev/pvc.yaml"

# Temporary directory for downloaded files
TEMP_DIR="${SCRIPT_DIR}/.odh-setup-temp"
PVC_NAME=""
MANIFEST_VOLUME_NAME="dashboard-manifests"
RHOAI_IMAGE_ENV_UPDATED="false"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                # Assume it's an image tag
                DASHBOARD_IMAGE_TAG="$1"
                shift
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [IMAGE_TAG]

Update ODH Dashboard to use a specific image tag.

Options:
    --skip-setup    Skip the one-time PVC and CSV patch setup
    --help, -h      Show this help message

Arguments:
    IMAGE_TAG       The image tag or digest to use (default: main)
                    Examples: main, pr-5476, v2.38.2-odh, sha256:abc123...

Environment Variables:
    DASHBOARD_IMAGE_REPO    Image repository (default: quay.io/opendatahub/odh-dashboard)
    DASHBOARD_IMAGE_TAG     Image tag (default: main)
    OPERATOR_NAMESPACE      Operator namespace (default: openshift-operators,
                              falls back to redhat-ods-operator)
    DASHBOARD_NAMESPACE     Dashboard namespace (default: opendatahub,
                              falls back to redhat-ods-applications)
    DASHBOARD_DEPLOYMENT_NAME
                            Dashboard deployment (default: odh-dashboard,
                              falls back to rhods-dashboard)
    OPERATOR_NAME           Operator name (default: opendatahub-operator,
                              falls back to rhods-operator)
    SKIP_SETUP              Skip PVC/CSV setup (default: false)

Examples:
    $(basename "$0")                              # Use main image
    $(basename "$0") pr-5476                      # Use PR image
    $(basename "$0") sha256:abc123...             # Use image digest
    $(basename "$0") --skip-setup main            # Skip setup, use main image
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

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed. Aborting."
        exit 1
    fi

    log_info "Prerequisites check passed."
    log_info "Logged in as: $(oc whoami)"
    log_info "Cluster: $(oc whoami --show-server)"
}

# Resolve the dashboard namespace and operator configuration for both ODH and
# RHOAI installations. Environment variables remain the first candidates.
resolve_cluster_configuration() {
    log_info "Detecting dashboard and operator resources..."

    if operator_deployment_exists "${OPERATOR_NAMESPACE}" "${OPERATOR_NAME}"; then
        log_info "Found ${OPERATOR_NAME} in ${OPERATOR_NAMESPACE}."
    elif operator_deployment_exists "${FALLBACK_OPERATOR_NAMESPACE}" "${FALLBACK_OPERATOR_NAME}"; then
        log_warn "Could not find ${OPERATOR_NAME} in ${OPERATOR_NAMESPACE}."
        OPERATOR_NAMESPACE="${FALLBACK_OPERATOR_NAMESPACE}"
        OPERATOR_NAME="${FALLBACK_OPERATOR_NAME}"
        log_info "Using ${OPERATOR_NAME} in ${OPERATOR_NAMESPACE}."
    else
        log_error "Could not find an operator deployment. Tried ${OPERATOR_NAME} in ${OPERATOR_NAMESPACE} and ${FALLBACK_OPERATOR_NAME} in ${FALLBACK_OPERATOR_NAMESPACE}."
        exit 1
    fi

    if oc get deploy "${DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" &> /dev/null; then
        log_info "Found ${DASHBOARD_DEPLOYMENT_NAME} in ${DASHBOARD_NAMESPACE}."
    elif [[ "${DASHBOARD_DEPLOYMENT_NAME}" != "${FALLBACK_DASHBOARD_DEPLOYMENT_NAME}" ]] && \
        oc get deploy "${FALLBACK_DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" &> /dev/null; then
        log_warn "Could not find ${DASHBOARD_DEPLOYMENT_NAME} in ${DASHBOARD_NAMESPACE}."
        DASHBOARD_DEPLOYMENT_NAME="${FALLBACK_DASHBOARD_DEPLOYMENT_NAME}"
        log_info "Using ${DASHBOARD_DEPLOYMENT_NAME} in ${DASHBOARD_NAMESPACE}."
    elif [[ "${DASHBOARD_NAMESPACE}" != "${FALLBACK_DASHBOARD_NAMESPACE}" ]] && \
        oc get deploy "${FALLBACK_DASHBOARD_DEPLOYMENT_NAME}" -n "${FALLBACK_DASHBOARD_NAMESPACE}" &> /dev/null; then
        log_warn "Could not find ${DASHBOARD_DEPLOYMENT_NAME} in ${DASHBOARD_NAMESPACE}."
        DASHBOARD_NAMESPACE="${FALLBACK_DASHBOARD_NAMESPACE}"
        DASHBOARD_DEPLOYMENT_NAME="${FALLBACK_DASHBOARD_DEPLOYMENT_NAME}"
        log_info "Using ${DASHBOARD_DEPLOYMENT_NAME} in ${DASHBOARD_NAMESPACE}."
    elif oc get namespace "${DASHBOARD_NAMESPACE}" &> /dev/null; then
        log_info "Using ${DASHBOARD_DEPLOYMENT_NAME} in ${DASHBOARD_NAMESPACE} for the dashboard."
    elif [[ "${DASHBOARD_NAMESPACE}" != "${FALLBACK_DASHBOARD_NAMESPACE}" ]] && \
        oc get namespace "${FALLBACK_DASHBOARD_NAMESPACE}" &> /dev/null; then
        log_warn "Could not find ${DASHBOARD_NAMESPACE}."
        DASHBOARD_NAMESPACE="${FALLBACK_DASHBOARD_NAMESPACE}"
        DASHBOARD_DEPLOYMENT_NAME="${FALLBACK_DASHBOARD_DEPLOYMENT_NAME}"
        log_info "Using ${DASHBOARD_DEPLOYMENT_NAME} in ${DASHBOARD_NAMESPACE} for the dashboard."
    else
        log_error "Could not find a dashboard namespace. Tried ${DASHBOARD_NAMESPACE} and ${FALLBACK_DASHBOARD_NAMESPACE}."
        exit 1
    fi

    log_info "Using dashboard namespace: ${DASHBOARD_NAMESPACE}"
    log_info "Using dashboard deployment: ${DASHBOARD_DEPLOYMENT_NAME}"
    log_info "Using operator: ${OPERATOR_NAME} in ${OPERATOR_NAMESPACE}"
}

# Check for an operator deployment by name first, then by the label used by
# the existing setup commands.
operator_deployment_exists() {
    local namespace="$1"
    local operator_name="$2"

    oc get deploy "${operator_name}" -n "${namespace}" &> /dev/null || \
        [[ -n "$(oc get deploy -n "${namespace}" -l "name=${operator_name}" --no-headers 2>/dev/null)" ]]
}

# Create a CSV patch for RHOAI without the fixed fsGroup used by the ODH
# component-development patch. RHOAI operator namespaces use restricted-v2,
# which only permits fsGroup values allocated to the namespace.
create_rhoai_csv_patch() {
    cat > "${TEMP_DIR}/csv-patch.json" <<EOF
[
  {
    "op": "add",
    "path": "/spec/install/spec/deployments/0/spec/replicas",
    "value": 1
  },
  {
    "op": "add",
    "path": "/spec/install/spec/deployments/0/spec/strategy",
    "value": { "type": "Recreate" }
  },
  {
    "op": "add",
    "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "${MANIFEST_VOLUME_NAME}",
      "mountPath": "/opt/manifests/dashboard"
    }
  },
  {
    "op": "add",
    "path": "/spec/install/spec/deployments/0/spec/template/spec/volumes/-",
    "value": {
      "name": "${MANIFEST_VOLUME_NAME}",
      "persistentVolumeClaim": {
        "claimName": "${PVC_NAME}"
      }
    }
  }
]
EOF
}

# Download setup files from GitHub
download_setup_files() {
    log_info "Downloading setup files from GitHub..."

    mkdir -p "${TEMP_DIR}"

    if [[ "${OPERATOR_NAME}" != "${FALLBACK_OPERATOR_NAME}" ]]; then
        log_info "Downloading csv-patch.json..."
        if ! curl -sSL -o "${TEMP_DIR}/csv-patch.json" "${CSV_PATCH_URL}"; then
            log_error "Failed to download csv-patch.json"
            exit 1
        fi
    fi

    log_info "Downloading pvc.yaml..."
    if ! curl -sSL -o "${TEMP_DIR}/pvc.yaml" "${PVC_URL}"; then
        log_error "Failed to download pvc.yaml"
        exit 1
    fi

    if [[ -z "${PVC_NAME}" ]]; then
        PVC_NAME=$(awk '
            /^metadata:/ { in_metadata=1; next }
            in_metadata && /^  name:/ { print $2; exit }
            /^[^ ]/ { in_metadata=0 }
        ' "${TEMP_DIR}/pvc.yaml")
    fi

    if [[ -z "${PVC_NAME}" ]]; then
        log_error "Could not determine the PVC name from ${TEMP_DIR}/pvc.yaml"
        exit 1
    fi

    if [[ "${OPERATOR_NAME}" == "${FALLBACK_OPERATOR_NAME}" ]]; then
        log_info "Creating RHOAI-compatible csv-patch.json for PVC ${PVC_NAME}..."
        create_rhoai_csv_patch
    fi

    log_info "Setup files downloaded to ${TEMP_DIR} (PVC: ${PVC_NAME})"
}

# Remove the fixed fsGroup that may have been added to the RHOAI CSV by an
# earlier run using the ODH component-development patch. Keep any other
# securityContext fields supplied by the RHOAI operator bundle.
remove_rhoai_fs_group() {
    local csv="$1"
    local fs_group
    fs_group=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.install.spec.deployments[0].spec.template.spec.securityContext.fsGroup}' \
        2>/dev/null || echo "")

    if [[ "${fs_group}" != "1001" ]]; then
        return 0
    fi

    log_warn "Removing incompatible fsGroup 1001 from RHOAI CSV ${csv}..."
    oc patch csv "${csv}" -n "${OPERATOR_NAMESPACE}" --type json --patch \
        '[{"op":"remove","path":"/spec/install/spec/deployments/0/spec/template/spec/securityContext/fsGroup"}]'
}

# Update the RHOAI related image used by the operator when rendering the
# dashboard overlay. This value takes precedence over params.env in RHOAI
# installations.
ensure_rhoai_dashboard_image_env() {
    local csv="$1"
    local env_index=0
    local env_name
    local current_image

    RHOAI_IMAGE_ENV_UPDATED="false"

    while IFS= read -r env_name; do
        if [[ "${env_name}" == "RELATED_IMAGE_ODH_DASHBOARD_IMAGE" ]]; then
            break
        fi
        env_index=$((env_index + 1))
    done < <(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{range .spec.install.spec.deployments[0].spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}')

    if [[ "${env_name:-}" != "RELATED_IMAGE_ODH_DASHBOARD_IMAGE" ]]; then
        log_error "Could not find RELATED_IMAGE_ODH_DASHBOARD_IMAGE in CSV ${csv}"
        return 1
    fi

    current_image=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath="{.spec.install.spec.deployments[0].spec.template.spec.containers[0].env[${env_index}].value}")

    if [[ "${current_image}" == "${DASHBOARD_IMAGE}" ]]; then
        return 0
    fi

    log_info "Updating RHOAI dashboard related image to ${DASHBOARD_IMAGE}..."
    if ! oc patch csv "${csv}" -n "${OPERATOR_NAMESPACE}" --type json --patch \
        "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/${env_index}/value\",\"value\":\"${DASHBOARD_IMAGE}\"}]"; then
        log_error "Failed to update the RHOAI dashboard related image in CSV ${csv}"
        return 1
    fi

    RHOAI_IMAGE_ENV_UPDATED="true"
}

# Keep the RHOAI operator deployment settings from the upstream component-dev
# patch when the manifest mount was added by an earlier script run.
ensure_rhoai_csv_deployment_settings() {
    local csv="$1"
    local replicas
    local strategy

    replicas=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.install.spec.deployments[0].spec.replicas}' \
        2>/dev/null || echo "")
    strategy=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.install.spec.deployments[0].spec.strategy.type}' \
        2>/dev/null || echo "")

    if [[ "${replicas}" == "1" && "${strategy}" == "Recreate" ]]; then
        return 0
    fi

    log_info "Configuring RHOAI operator deployment for a single replica with Recreate strategy..."
    oc patch csv "${csv}" -n "${OPERATOR_NAMESPACE}" --type json --patch \
        '[
          {"op":"add","path":"/spec/install/spec/deployments/0/spec/replicas","value":1},
          {"op":"add","path":"/spec/install/spec/deployments/0/spec/strategy","value":{"type":"Recreate"}}
        ]'
}

# Apply PVC for manifest storage
apply_pvc() {
    log_info "Checking if PVC already exists..."

    if oc get pvc -n "${OPERATOR_NAMESPACE}" "${PVC_NAME}" &> /dev/null; then
        log_info "PVC '${PVC_NAME}' already exists. Skipping PVC creation."
        return 0
    fi

    log_info "Applying PVC to ${OPERATOR_NAMESPACE} namespace..."
    oc apply -f "${TEMP_DIR}/pvc.yaml" -n "${OPERATOR_NAMESPACE}"
    log_info "PVC applied successfully."
}

# Patch the CSV to enable manifest override
find_operator_csv() {
    oc get csv -n "${OPERATOR_NAMESPACE}" -o name | grep "${OPERATOR_NAME}" | head -n1 | cut -d/ -f2
}

patch_csv() {
    log_info "Finding operator CSV..."

    local csv
    csv=$(find_operator_csv)

    if [[ -z "$csv" ]]; then
        log_error "Could not find ${OPERATOR_NAME} CSV in ${OPERATOR_NAMESPACE}"
        exit 1
    fi

    log_info "Found CSV: ${csv}"

    if [[ "${OPERATOR_NAME}" == "${FALLBACK_OPERATOR_NAME}" ]]; then
        if ! remove_rhoai_fs_group "${csv}"; then
            log_error "Failed to remove the incompatible fsGroup from RHOAI CSV ${csv}"
            exit 1
        fi
        if ! ensure_rhoai_dashboard_image_env "${csv}"; then
            exit 1
        fi
    fi

    # Check the mount path rather than the PVC name. RHOAI may already mount
    # this path with a different volume/PVC name.
    local volume_mounts
    volume_mounts=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.spec.install.spec.deployments[0].spec.template.spec.containers[0].volumeMounts}' 2>/dev/null || echo "")

    if echo "${volume_mounts}" | grep -qF "/opt/manifests/dashboard"; then
        if [[ "${OPERATOR_NAME}" == "${FALLBACK_OPERATOR_NAME}" ]]; then
            if ! ensure_rhoai_csv_deployment_settings "${csv}"; then
                log_error "Failed to configure the RHOAI operator deployment settings"
                exit 1
            fi
        fi
        log_info "CSV already has the dashboard manifest mount. Skipping CSV patch."
        return 0
    fi

    log_info "Patching CSV ${csv}..."
    if ! oc patch csv "${csv}" -n "${OPERATOR_NAMESPACE}" --type json --patch-file "${TEMP_DIR}/csv-patch.json"; then
        log_error "Failed to patch CSV ${csv}"
        exit 1
    else
        log_info "CSV patched successfully."
    fi
}

# Wait for operator pod to be ready
wait_for_operator_pod() {
    local max_attempts="${1:-60}"
    local attempt=0

    log_info "Waiting for operator pod to be ready..."

    # First, wait a bit for any pod termination to start
    sleep 10

    while [[ $attempt -lt $max_attempts ]]; do
        # Get pod count first
        local pod_count
        pod_count=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l "name=${OPERATOR_NAME}" --no-headers 2>/dev/null | wc -l || echo "0")

        if [[ "$pod_count" -eq 0 ]]; then
            log_info "No operator pod found yet, waiting for new pod to be created... (attempt $((attempt + 1))/$max_attempts)"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        # Check if any pod is in Terminating state
        local terminating
        terminating=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l "name=${OPERATOR_NAME}" -o jsonpath='{.items[*].metadata.deletionTimestamp}' 2>/dev/null || echo "")

        if [[ -n "$terminating" ]]; then
            log_info "Operator pod is terminating, waiting... (attempt $((attempt + 1))/$max_attempts)"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        # Get the pod status
        local pod_status
        pod_status=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l "name=${OPERATOR_NAME}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

        if [[ "$pod_status" == "Running" ]]; then
            # Also check if pod is ready
            local ready
            ready=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l "name=${OPERATOR_NAME}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [[ "$ready" == "True" ]]; then
                log_info "Operator pod is ready."
                return 0
            else
                log_info "Pod is running but not ready yet... (attempt $((attempt + 1))/$max_attempts)"
            fi
        elif [[ "$pod_status" == "Pending" ]]; then
            log_info "Pod is pending... (attempt $((attempt + 1))/$max_attempts)"
        elif [[ "$pod_status" == "ContainerCreating" ]]; then
            log_info "Pod container is being created... (attempt $((attempt + 1))/$max_attempts)"
        else
            log_info "Pod status: ${pod_status:-unknown}... (attempt $((attempt + 1))/$max_attempts)"
        fi

        sleep 5
        attempt=$((attempt + 1))
    done

    log_warn "Operator pod did not become ready in time, but continuing anyway..."
    return 0
}

# Perform one-time setup (PVC and CSV patch)
perform_one_time_setup() {
    log_step "Performing one-time setup (PVC and CSV patch)..."

    download_setup_files
    apply_pvc
    patch_csv

    # Wait for operator pod to restart after CSV patch
    wait_for_operator_pod 60

    log_info "One-time setup complete."
}

# Update the distribution params with the new dashboard image
update_deployment_manifest() {
    local image="${DASHBOARD_IMAGE}"
    local manifest_distribution="odh"

    if [[ "${OPERATOR_NAME}" == "${FALLBACK_OPERATOR_NAME}" ]]; then
        manifest_distribution="rhoai"
    fi

    log_info "Updating ${manifest_distribution}/params.env with image: ${image}"

    local params_file="${MANIFESTS_DIR}/${manifest_distribution}/params.env"

    if [[ ! -f "${params_file}" ]]; then
        log_error "Manifest parameters file not found: ${params_file}"
        exit 1
    fi

    # Create a temporary copy of the manifests
    local temp_manifests="${TEMP_DIR}/manifests"
    rm -rf "${temp_manifests}"
    cp -r "${MANIFESTS_DIR}" "${temp_manifests}"

    # Kustomize replaces this parameter into base/deployment.yaml and the
    # distribution-specific overlays. Note: Using -i.bak with rm for
    # cross-platform compatibility (BSD/GNU sed).
    local temp_params="${temp_manifests}/${manifest_distribution}/params.env"
    if ! grep -q '^odh-dashboard-image=' "${temp_params}"; then
        log_error "Could not find odh-dashboard-image in ${temp_params}"
        exit 1
    fi

    sed -i.bak "s|^odh-dashboard-image=.*|odh-dashboard-image=${image}|" "${temp_params}" && rm -f "${temp_params}.bak"
    log_info "Updated ${manifest_distribution}/params.env with ${image}"

    log_info "Manifest parameters updated."
}

# Get the operator pod name
get_operator_pod() {
    local pod
    pod=$(oc get pod -n "${OPERATOR_NAMESPACE}" -l "name=${OPERATOR_NAME}" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")

    if [[ -z "$pod" ]]; then
        log_error "Could not find ${OPERATOR_NAME} pod in ${OPERATOR_NAMESPACE}"
        exit 1
    fi

    echo "$pod"
}

# Get the container receiving the manifest volume. The CSV patch targets the
# first operator container, but its name differs between ODH and RHOAI.
get_operator_container() {
    local pod="$1"
    local container
    container=$(oc get pod "${pod}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath="{.spec.containers[0].name}" 2>/dev/null || echo "")

    if [[ -z "${container}" ]]; then
        log_error "Could not determine the operator container in pod ${pod}"
        exit 1
    fi

    echo "${container}"
}

# Copy manifests to the operator pod
copy_manifests_to_pod() {
    log_info "Finding operator pod..."

    local op_pod
    op_pod=$(get_operator_pod)
    log_info "Using pod: ${op_pod}"

    local op_container
    op_container=$(get_operator_container "${op_pod}")
    log_info "Using container: ${op_container}"

    # Wait for pod to be ready
    log_info "Waiting for operator pod to be ready..."
    if ! oc wait pod/"${op_pod}" -n "${OPERATOR_NAMESPACE}" --for=condition=Ready --timeout=60s; then
        log_error "Operator pod did not become ready in time"
        exit 1
    fi

    # Copy manifests to the pod
    log_info "Copying manifests to pod..."
    local temp_manifests="${TEMP_DIR}/manifests"

    if ! oc cp "${temp_manifests}/." "${OPERATOR_NAMESPACE}/${op_pod}:/opt/manifests/dashboard" -c "${op_container}"; then
        log_error "Failed to copy manifests to operator pod"
        exit 1
    fi

    log_info "Manifests copied successfully."
}

# Restart the operator deployment
restart_operator() {
    log_info "Restarting operator deployment..."

    oc rollout restart deploy -n "${OPERATOR_NAMESPACE}" -l "name=${OPERATOR_NAME}"

    log_info "Waiting for operator rollout to complete..."
    if ! oc rollout status deploy -n "${OPERATOR_NAMESPACE}" -l "name=${OPERATOR_NAME}" --timeout=120s; then
        log_warn "Operator rollout may still be in progress"
    fi

    log_info "Operator restarted."
}

# Wait for dashboard deployment to be ready
wait_for_dashboard() {
    log_info "Waiting for dashboard deployment to update..."

    local max_attempts=60
    local attempt=0
    local expected_image="${DASHBOARD_IMAGE}"

    while [[ $attempt -lt $max_attempts ]]; do
        # Check if dashboard deployment exists
        if ! oc get deploy "${DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" &> /dev/null; then
            log_info "Dashboard deployment not found yet... (attempt $((attempt + 1))/$max_attempts)"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        # Get current image
        local current_image
        current_image=$(oc get deploy "${DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

        if [[ "$current_image" == "$expected_image" ]]; then
            log_info "Dashboard image updated to: ${current_image}"

            # Wait for deployment to be available
            log_info "Waiting for dashboard pods to be ready..."
            if oc rollout status "deploy/${DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" --timeout=300s; then
                log_info "Dashboard deployment is ready."
                return 0
            fi
        fi

        log_info "Current image: ${current_image:-not set}"
        log_info "Expected image: ${expected_image}"
        log_info "Waiting for image update... (attempt $((attempt + 1))/$max_attempts)"
        sleep 10
        attempt=$((attempt + 1))
    done

    log_warn "Dashboard may still be updating. Check status manually."
    return 0
}

# Verify the installation
verify_installation() {
    log_info "Verifying installation..."

    echo ""
    echo "=============================================="
    echo "Installation Summary"
    echo "=============================================="

    echo ""
    echo "Dashboard Deployment:"
    echo "---------------------"
    if oc get deploy "${DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" &> /dev/null; then
        local current_image
        current_image=$(oc get deploy "${DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}')
        echo "  Image: ${current_image}"

        local replicas
        replicas=$(oc get deploy "${DASHBOARD_DEPLOYMENT_NAME}" -n "${DASHBOARD_NAMESPACE}" -o jsonpath='{.status.readyReplicas}')
        echo "  Ready Replicas: ${replicas:-0}"
    else
        echo "  Dashboard deployment not found"
    fi

    echo ""
    echo "Dashboard Status:"
    echo "-----------------"
    if oc get dashboard default-dashboard -n "${DASHBOARD_NAMESPACE}" &> /dev/null; then
        oc get dashboard default-dashboard -n "${DASHBOARD_NAMESPACE}" -o yaml | grep -A6 "message:" || echo "  No status message found"
    else
        echo "  Dashboard CR not found"
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

    # Build the full image reference: use @ for sha digests, : for tags
    if [[ "${DASHBOARD_IMAGE_TAG}" == sha256:* ]]; then
        DASHBOARD_IMAGE="${DASHBOARD_IMAGE_REPO}@${DASHBOARD_IMAGE_TAG}"
    else
        DASHBOARD_IMAGE="${DASHBOARD_IMAGE_REPO}:${DASHBOARD_IMAGE_TAG}"
    fi

    echo "=============================================="
    echo "ODH Dashboard Image Update Script"
    echo "=============================================="
    echo ""
    echo "Configuration:"
    echo "  Image: ${DASHBOARD_IMAGE}"
    echo "  Skip Setup: ${SKIP_SETUP}"
    echo "  Manifests Dir: ${MANIFESTS_DIR}"
    echo ""

    check_prerequisites
    resolve_cluster_configuration

    # Create temp directory
    mkdir -p "${TEMP_DIR}"

    # Trap to cleanup on exit
    trap cleanup EXIT

    if [[ "${SKIP_SETUP}" != "true" ]]; then
        echo ""
        log_step "Step 1/4: Performing one-time setup..."
        perform_one_time_setup
    else
        log_info "Skipping one-time setup (--skip-setup flag provided)"
    fi

    if [[ "${SKIP_SETUP}" == "true" && "${OPERATOR_NAME}" == "${FALLBACK_OPERATOR_NAME}" ]]; then
        log_info "Checking the RHOAI dashboard related image override..."
        local csv
        csv=$(find_operator_csv)
        if [[ -z "${csv}" ]]; then
            log_error "Could not find ${OPERATOR_NAME} CSV in ${OPERATOR_NAMESPACE}"
            exit 1
        fi
        if ! ensure_rhoai_dashboard_image_env "${csv}"; then
            exit 1
        fi
        if [[ "${RHOAI_IMAGE_ENV_UPDATED}" == "true" ]]; then
            wait_for_operator_pod 60
        fi
    fi

    echo ""
    log_step "Step 2/4: Updating dashboard image in manifests..."
    update_deployment_manifest

    echo ""
    log_step "Step 3/4: Copying manifests to operator pod..."
    copy_manifests_to_pod

    echo ""
    log_step "Step 4/4: Restarting operator..."
    restart_operator

    echo ""
    log_info "Waiting for dashboard to update..."
    wait_for_dashboard

    echo ""
    verify_installation

    echo ""
    log_info "Done!"
    echo ""
    echo "The dashboard image has been updated to: ${DASHBOARD_IMAGE}"
    echo ""
    echo "You can verify the running image with:"
    echo "  oc get deploy ${DASHBOARD_DEPLOYMENT_NAME} -n ${DASHBOARD_NAMESPACE} -o=jsonpath='{.spec.template.spec.containers[0].image}'"
    echo ""
    echo "To use a different image in the future, run:"
    echo "  $(basename "$0") --skip-setup <image-tag>"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") --skip-setup main              # Latest main branch"
    echo "  $(basename "$0") --skip-setup pr-5476           # Specific PR"
    echo "  $(basename "$0") --skip-setup sha256:abc123...  # Specific digest"
    echo ""
}

# Run main function
main "$@"
