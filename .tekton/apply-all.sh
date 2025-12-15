#!/usr/bin/env bash
# apply-all.sh
# Apply Tekton resources from the .tekton directory in the recommended order,
# wait for critical resources, optionally expose EventListener via an OpenShift route.
#
# Usage:
#   ./apply-all.sh                 # apply to default namespace (SN_OC_NS or sn-labs-ayoubchaieb7)
#   ./apply-all.sh --namespace my-ns
#   ./apply-all.sh --namespace my-ns --expose-eventlistener
#   ./apply-all.sh --namespace my-ns --expose-eventlistener --run-pipelinerun
#
# Notes:
#  - Requires kubectl. For route/expose features the script will use oc if available.
#  - tkn is optional but useful for status output.
#  - Adjust FILE_ORDER below if your folder layout differs.

set -euo pipefail
IFS=$'\n\t'

# Defaults
DEFAULT_NS="${SN_OC_NS:-sn-labs-ayoubchaieb7}"
NAMESPACE="$DEFAULT_NS"
EXPOSE_EL=false
RUN_PIPELINERUN=false
PORT_FORWARD_TEST=false

# Helper: print usage
usage() {
  cat <<EOF
Usage: $0 [--namespace NAMESPACE] [--expose-eventlistener] [--run-pipelinerun] [--port-forward-test]
  --namespace NAMESPACE        Namespace to apply resources into (default: $DEFAULT_NS)
  --expose-eventlistener      After applying, try to expose the EventListener service via 'oc expose'
  --run-pipelinerun           Apply the pipelinerun.yaml (manual run) after pipeline is created
  --port-forward-test         Port-forward EventListener to localhost:8090 and show curl test command (does NOT auto-post)
  -h|--help                   Show this message
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2;;
    --expose-eventlistener) EXPOSE_EL=true; shift;;
    --run-pipelinerun) RUN_PIPELINERUN=true; shift;;
    --port-forward-test) PORT_FORWARD_TEST=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1"; usage; exit 1;;
  esac
done

# Tools check
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH. Install/obtain kubectl and try again."; exit 1; }
OC_CMD="oc"
if ! command -v "${OC_CMD}" >/dev/null 2>&1; then
  OC_CMD=""   # oc optional; route/expose will be skipped if not present
fi
TKN_CMD="tkn"
TKN_AVAILABLE=true
if ! command -v "${TKN_CMD}" >/dev/null 2>&1; then
  TKN_AVAILABLE=false
fi

# Repo paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
TEKTON_DIR="$ROOT_DIR/.tekton"

# Files order (adjust if your filenames differ)
FILE_ORDER=(
  "$TEKTON_DIR/clustertasks.yaml"
  "$TEKTON_DIR/tasks.yml"
  "$TEKTON_DIR/storageclass-skills-class-learner.yaml"
  "$TEKTON_DIR/pvc.yaml"
  "$TEKTON_DIR/pipeline-output.yaml"
  "$TEKTON_DIR/triggerbinding.yaml"
  "$TEKTON_DIR/triggertemplate.yaml"
  "$TEKTON_DIR/eventlistener.yaml"
)

PIPELINERUN_FILE="$TEKTON_DIR/pipelinerun.yaml"

echo
echo "== Tekton apply helper =="
echo "Namespace: $NAMESPACE"
echo "Tekton dir: $TEKTON_DIR"
echo "oc available: ${OC_CMD:-no}"
echo "tkn available: ${TKN_AVAILABLE}"
echo

# Ensure namespace exists / switch context
echo "Switching to namespace: $NAMESPACE"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl config set-context --current --namespace="$NAMESPACE" || true
else
  echo "Namespace '$NAMESPACE' not found. Creating..."
  kubectl create namespace "$NAMESPACE"
  kubectl config set-context --current --namespace="$NAMESPACE" || true
fi

# Helper: apply file if exists
apply_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    echo
    echo "Applying: $f"
    kubectl apply -f "$f" -n "$NAMESPACE"
  else
    echo "Skipping (not found): $f"
  fi
}

# Apply files in order
for f in "${FILE_ORDER[@]}"; do
  apply_if_exists "$f"
done

# Optionally apply pipelinerun (manual run)
if [[ "$RUN_PIPELINERUN" == true ]]; then
  if [[ -f "$PIPELINERUN_FILE" ]]; then
    echo
    echo "Applying pipelinerun manifest: $PIPELINERUN_FILE"
    kubectl apply -f "$PIPELINERUN_FILE" -n "$NAMESPACE"
  else
    echo "No pipelinerun.yaml found to apply."
  fi
fi

# Wait helper
wait_for_pod_running() {
  local selector="$1"
  local timeout=${2:-120}
  echo
  echo "Waiting for pod matching selector '$selector' to be Ready (timeout ${timeout}s)..."
  local start ts
  start=$(date +%s)
  while true; do
    # Check for any pod that matches and is Ready
    pod=$(kubectl get pods -n "$NAMESPACE" --selector="$selector" --no-headers 2>/dev/null | awk '{print $1}' | head -n1 || true)
    if [[ -n "$pod" ]]; then
      status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      ready=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
      if [[ "$status" == "Running" && "$ready" == "true" ]]; then
        echo "Pod $pod is Running and Ready."
        return 0
      fi
    fi
    ts=$(($(date +%s)-start))
    if (( ts > timeout )); then
      echo "Timeout waiting for pods matching '$selector'."
      return 1
    fi
    sleep 3
  done
}

# Try to detect EventListener service name
EL_SVC=""
echo
echo "Detecting EventListener service in namespace $NAMESPACE..."
# common service name patterns: el-*, cd-listener, eventlistener-*
EL_SVC=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E 'el-|eventlistener|cd-listener|cd-listener' | head -n1 || true)
if [[ -z "$EL_SVC" ]]; then
  # attempt to find by label
  EL_SVC=$(kubectl get svc -n "$NAMESPACE" --selector=app.kubernetes.io/component=eventlistener -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [[ -n "$EL_SVC" ]]; then
  echo "Found EventListener service: $EL_SVC"
  # wait for a pod that probably corresponds to it
  # attempt to find an EventListener Pod
  EL_POD_SELECTOR="eventlistener=${EL_SVC}"
  # fallback selector
  if ! wait_for_pod_running "$EL_POD_SELECTOR" 60; then
    echo "Could not confirm a pod for EventListener using selector '$EL_POD_SELECTOR'."
    echo "You can check pods with: kubectl get pods -n $NAMESPACE"
  fi
else
  echo "EventListener service not auto-detected. Check 'kubectl get svc -n $NAMESPACE'."
fi

# Optionally expose EventListener via oc expose (OpenShift Route)
if [[ "$EXPOSE_EL" == true ]]; then
  if [[ -z "$OC_CMD" ]]; then
    echo "oc is not available on PATH; cannot expose EventListener via route. Install 'oc' to use this feature."
  else
    if [[ -z "$EL_SVC" ]]; then
      echo "EventListener service not found; skipping route expose."
    else
      echo
      echo "Exposing EventListener service '$EL_SVC' via OpenShift Route (namespace: $NAMESPACE)..."
      set +e
      ${OC_CMD} expose svc/"$EL_SVC" -n "$NAMESPACE"
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        ROUTE_HOST=$(${OC_CMD} get route -n "$NAMESPACE" --selector=app.kubernetes.io/component=eventlistener -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
        # fallback: try route for service name
        if [[ -z "$ROUTE_HOST" ]]; then
          ROUTE_HOST=$(${OC_CMD} get route "$EL_SVC" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
        fi
        echo "Route created. Host: ${ROUTE_HOST:-(not found)}"
        if [[ -n "$ROUTE_HOST" ]]; then
          echo "Webhook URL: http://${ROUTE_HOST}/"
          echo "Configure your GitHub webhook payload URL to that value (Content type: application/json)."
        else
          echo "Could not determine route host automatically; run: oc get route -n $NAMESPACE"
        fi
      else
        echo "oc expose failed (rc=$rc). You may need permissions or the service may already be exposed."
      fi
    fi
  fi
fi

# Optionally provide port-forward test command
if [[ "$PORT_FORWARD_TEST" == true ]]; then
  if [[ -z "$EL_SVC" ]]; then
    echo "EventListener service not found; cannot port-forward."
  else
    echo
    echo "To test locally using port-forward, run this in a separate terminal:"
    echo "  kubectl port-forward service/${EL_SVC} 8090:8080 -n ${NAMESPACE}"
    echo
    echo "Then, from another terminal, POST a test payload (example):"
    echo "  curl -X POST http://localhost:8090 -H 'Content-Type: application/json' \\"
    echo "    -d '{\"ref\":\"refs/heads/main\",\"repository\":{\"url\":\"https://github.com/ibm-developer-skills-network/wtecc-CICD_PracticeCode\"}}'"
  fi
fi

# Show short summary (tkn info if available)
echo
echo "=== Summary / quick checks ==="
kubectl get all -n "$NAMESPACE" || true

if [[ "$TKN_AVAILABLE" == true ]]; then
  echo
  echo "Tekton pipelines:"
  tkn pipeline ls -n "$NAMESPACE" || true
  echo "Tekton pipelineruns:"
  tkn pipelinerun ls -n "$NAMESPACE" || true
  echo "Tekton eventlisteners:"
  tkn eventlistener ls -n "$NAMESPACE" || true
fi

echo
echo "Done. If you want me to also generate a small test script that performs the port-forward and posts the test curl payload automatically, ask and I'll add it."
