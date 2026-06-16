#!/usr/bin/env bash
# TLS Scanner for Kuadrant on Kind
#
# Deploys a full Kuadrant stack on a Kind cluster and runs the OpenShift
# tls-scanner to audit the TLS posture of all components. Produces CSV/JSON
# reports in _output/tls-scan/.
#
# Usage:
#   utils/tls-scan.sh setup      # Kind cluster + Kuadrant stack + sample policies
#   utils/tls-scan.sh scan       # Build tls-scanner, run Job, collect results
#   utils/tls-scan.sh results    # Print summary of the last scan
#   utils/tls-scan.sh cleanup    # Delete Kind cluster + temp files
#   utils/tls-scan.sh all        # setup + scan + results
#
# Optional components (auto-detected from sibling repos):
#   - mcp-gateway: set MCP_GATEWAY_DIR or place repo at ../mcp-gateway
#   - CoreDNS: set DNS_OPERATOR_DIR or place repo at ../dns-operator

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/_output/tls-scan"
SCANNER_CLONE_DIR="${REPO_ROOT}/_output/tls-scanner"
SCANNER_IMAGE="${SCANNER_IMAGE:-localhost/tls-scanner:latest}"
SCANNER_NAMESPACE="${SCANNER_NAMESPACE:-tls-scanner}"
NAMESPACE_FILTER="${NAMESPACE_FILTER:-kuadrant-system,gateway-system,istio-system,cert-manager,mcp-system,kuadrant-coredns}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kuadrant-local}"
MCP_GATEWAY_DIR="${MCP_GATEWAY_DIR:-$(cd "${REPO_ROOT}/../mcp-gateway" 2>/dev/null && pwd || echo "")}"
DNS_OPERATOR_DIR="${DNS_OPERATOR_DIR:-$(cd "${REPO_ROOT}/../dns-operator" 2>/dev/null && pwd || echo "")}"
SCANNER_PARALLEL="${SCANNER_PARALLEL:-2}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-900}"
GATEWAY_NAME="kuadrant-ingressgateway"
GATEWAY_NS="gateway-system"

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

wait_for() {
    local desc="$1"; shift
    local timeout="${1:-120}"; shift
    info "Waiting for ${desc} (timeout ${timeout}s)..."
    if ! "$@" --timeout="${timeout}s" 2>/dev/null; then
        warn "Timed out waiting for ${desc}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# setup: Kind cluster + full Kuadrant stack + sample workload + policies
# ---------------------------------------------------------------------------
cmd_setup() {
    info "Setting up Kind cluster with full Kuadrant stack..."
    cd "${REPO_ROOT}"

    # Create cluster and deploy all operators
    make local-setup GATEWAYAPI_PROVIDER=istio

    info "Creating Kuadrant CR to activate the control plane..."
    kubectl apply -n kuadrant-system -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant-sample
spec: {}
EOF
    sleep 5

    info "Deploying toystore backend and HTTPRoute..."
    kubectl apply -f examples/toystore/toystore.yaml
    kubectl apply -f examples/toystore/httproute.yaml
    kubectl wait -n default --for=condition=Available deployment/toystore --timeout=120s

    info "Creating self-signed ClusterIssuer for TLSPolicy..."
    kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: self-signed-ca
spec:
  selfSigned: {}
EOF

    info "Adding HTTPS listener to Gateway..."
    kubectl apply -n "${GATEWAY_NS}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio: ingressgateway
  name: ${GATEWAY_NAME}
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    port: 443
    protocol: HTTPS
    hostname: "*.toystore.com"
    tls:
      mode: Terminate
      certificateRefs:
      - name: toystore-tls
        kind: Secret
    allowedRoutes:
      namespaces:
        from: All
EOF

    info "Applying TLSPolicy..."
    kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: TLSPolicy
metadata:
  name: toystore-tls
  namespace: ${GATEWAY_NS}
spec:
  targetRef:
    name: ${GATEWAY_NAME}
    group: gateway.networking.k8s.io
    kind: Gateway
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: selfsigned-issuer
EOF

    info "Waiting for Authorino and Limitador data plane pods..."
    kubectl wait -n kuadrant-system --for=condition=Available deployment --all --timeout=300s 2>/dev/null || true

    info "Provisioning TLS certificates for Authorino..."
    kubectl apply -n kuadrant-system -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: authorino-server-cert
spec:
  secretName: authorino-server-cert
  issuerRef:
    kind: ClusterIssuer
    name: selfsigned-issuer
  dnsNames:
  - authorino-authorino.kuadrant-system.svc
  - authorino-authorino.kuadrant-system.svc.cluster.local
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: authorino-oidc-cert
spec:
  secretName: authorino-oidc-cert
  issuerRef:
    kind: ClusterIssuer
    name: selfsigned-issuer
  dnsNames:
  - authorino-authorino.kuadrant-system.svc
  - authorino-authorino.kuadrant-system.svc.cluster.local
EOF
    kubectl wait -n kuadrant-system --for=condition=Ready certificate/authorino-server-cert --timeout=60s
    kubectl wait -n kuadrant-system --for=condition=Ready certificate/authorino-oidc-cert --timeout=60s

    info "Enabling TLS on Authorino..."
    kubectl patch authorino authorino -n kuadrant-system --type=merge -p '
    {
      "spec": {
        "listener": {
          "tls": {
            "enabled": true,
            "certSecretRef": {"name": "authorino-server-cert"}
          }
        },
        "oidcServer": {
          "tls": {
            "enabled": true,
            "certSecretRef": {"name": "authorino-oidc-cert"}
          }
        }
      }
    }'
    sleep 5
    kubectl wait -n kuadrant-system --for=condition=Available deployment/authorino --timeout=120s 2>/dev/null || true

    info "Applying AuthPolicy..."
    kubectl apply -f config/samples/kuadrant_v1_authpolicy.yaml

    info "Applying RateLimitPolicy..."
    kubectl apply -f config/samples/kuadrant_v1_ratelimitpolicy.yaml

    info "Waiting for policies to be reconciled..."
    sleep 10

    # Deploy mcp-gateway if the repo is available
    if [[ -n "${MCP_GATEWAY_DIR}" && -d "${MCP_GATEWAY_DIR}" ]]; then
        info "Deploying mcp-gateway from ${MCP_GATEWAY_DIR}..."
        cd "${MCP_GATEWAY_DIR}"

        info "Building mcp-gateway images..."
        make build-image

        info "Loading mcp-gateway images into Kind..."
        make load-image KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}"

        info "Installing mcp-gateway CRDs and deploying controller..."
        make install-crd
        kubectl apply -k config/mcp-gateway/overlays/mcp-system/ 2>/dev/null || true
        kubectl wait -n mcp-system --for=condition=Available deployment/mcp-gateway-controller --timeout=120s

        info "Creating ReferenceGrant for cross-namespace Gateway access..."
        kubectl apply -n "${GATEWAY_NS}" -f - <<REFEOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: mcp-gateway-ref
spec:
  from:
  - group: mcp.kuadrant.io
    kind: MCPGatewayExtension
    namespace: mcp-system
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: mcp-system
  to:
  - group: gateway.networking.k8s.io
    kind: Gateway
REFEOF

        info "Patching MCPGatewayExtension to target existing Gateway..."
        kubectl apply -n mcp-system -f - <<MCPEOF
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPGatewayExtension
metadata:
  name: mcp-gateway-extension
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GATEWAY_NAME}
    namespace: ${GATEWAY_NS}
    sectionName: http
  publicHost: "mcp.127-0-0-1.sslip.io"
  httpRouteManagement: Enabled
MCPEOF
        kubectl wait -n mcp-system --for=condition=Ready mcpgatewayextension/mcp-gateway-extension --timeout=120s 2>/dev/null || warn "MCPGatewayExtension not Ready — broker-router may not be running"

        info "Deploying test MCP server..."
        make deploy-everything-server KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" 2>/dev/null || true

        cd "${REPO_ROOT}"
    else
        warn "mcp-gateway repo not found at ${MCP_GATEWAY_DIR:-../mcp-gateway} — skipping"
    fi

    # Deploy CoreDNS if dns-operator repo is available
    if [[ -n "${DNS_OPERATOR_DIR}" && -d "${DNS_OPERATOR_DIR}" ]]; then
        info "Deploying CoreDNS from ${DNS_OPERATOR_DIR}..."
        cd "${DNS_OPERATOR_DIR}"

        info "Building CoreDNS image..."
        make coredns-docker-build

        info "Loading CoreDNS image into Kind..."
        make coredns-kind-load-image KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}"

        info "Installing CoreDNS..."
        make install-coredns-unmonitored

        cd "${REPO_ROOT}"
    else
        warn "dns-operator repo not found at ${DNS_OPERATOR_DIR:-../dns-operator} — skipping CoreDNS"
    fi

    info "Checking pod status across target namespaces..."
    for ns in kuadrant-system gateway-system istio-system cert-manager mcp-system kuadrant-coredns; do
        echo "--- ${ns} ---"
        kubectl get pods -n "${ns}" --no-headers 2>/dev/null || echo "  (namespace not found)"
    done

    info "Setup complete."
}

# ---------------------------------------------------------------------------
# scan: build tls-scanner, deploy Job, collect results
# ---------------------------------------------------------------------------
cmd_scan() {
    mkdir -p "${OUTPUT_DIR}"

    # Clone or update tls-scanner
    if [[ -d "${SCANNER_CLONE_DIR}/.git" ]]; then
        info "Updating tls-scanner clone..."
        git -C "${SCANNER_CLONE_DIR}" pull --ff-only 2>/dev/null || true
    else
        info "Cloning openshift/tls-scanner..."
        mkdir -p "$(dirname "${SCANNER_CLONE_DIR}")"
        git clone --depth 1 https://github.com/openshift/tls-scanner.git "${SCANNER_CLONE_DIR}"
    fi

    info "Building tls-scanner image for Kind..."
    # Generate a Kind-compatible Dockerfile (no OCP base images, no oc CLI)
    cat > "${SCANNER_CLONE_DIR}/Dockerfile.kind" <<'DOCKERFILE'
FROM golang:1.25 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 GOOS=linux go build -mod=readonly -ldflags="-s -w" -o bin/tls-scanner ./cmd/tls-scanner

FROM debian:bookworm-slim
ARG TESTSSL_VERSION=3.2.2
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl jq bash lsof dnsutils net-tools procps curl ca-certificates \
    bsdmainutils socat bind9-host \
    && rm -rf /var/lib/apt/lists/*
RUN curl -L "https://testssl.sh/testssl.sh-${TESTSSL_VERSION}.tar.gz" -o /tmp/testssl.tar.gz \
    && mkdir -p /opt/testssl \
    && tar -xzf /tmp/testssl.tar.gz -C /opt/testssl --strip-components=1 \
    && chmod +x /opt/testssl/testssl.sh \
    && ln -s /opt/testssl/testssl.sh /usr/local/bin/testssl.sh \
    && rm -f /tmp/testssl.tar.gz
COPY --from=builder /app/bin/tls-scanner /usr/local/bin/tls-scanner
ENTRYPOINT ["/usr/local/bin/tls-scanner"]
DOCKERFILE

    docker build -t "${SCANNER_IMAGE}" -f "${SCANNER_CLONE_DIR}/Dockerfile.kind" "${SCANNER_CLONE_DIR}"

    info "Loading scanner image into Kind cluster..."
    kind load docker-image "${SCANNER_IMAGE}" --name "${KIND_CLUSTER_NAME}"

    info "Deploying scanner Job..."
    kubectl create namespace "${SCANNER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tls-scanner
  namespace: ${SCANNER_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tls-scanner
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["services", "endpoints", "namespaces"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments", "daemonsets", "statefulsets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tls-scanner
subjects:
- kind: ServiceAccount
  name: tls-scanner
  namespace: ${SCANNER_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: tls-scanner
  apiGroup: rbac.authorization.k8s.io
EOF

    # Delete any previous Job
    kubectl delete job tls-scanner-job -n "${SCANNER_NAMESPACE}" --ignore-not-found=true

    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: tls-scanner-job
  namespace: ${SCANNER_NAMESPACE}
spec:
  backoffLimit: 1
  template:
    spec:
      serviceAccountName: tls-scanner
      containers:
      - name: tls-scanner
        image: ${SCANNER_IMAGE}
        imagePullPolicy: Never
        command: ["/bin/bash", "-c"]
        args:
          - |
            /usr/local/bin/tls-scanner \
              --all-pods \
              -j ${SCANNER_PARALLEL} \
              --artifact-dir /artifacts \
              --json-file /artifacts/results.json \
              --csv-file /artifacts/results.csv \
              --timing-file /artifacts/timing.txt \
              --log-file /artifacts/scan.log \
              --namespace-filter ${NAMESPACE_FILTER} &
            SCANNER_PID=\$!
            wait \$SCANNER_PID
            exit_code=\$?
            echo "Scanner finished with exit code: \$exit_code"
            echo "Keeping pod alive for artifact collection..."
            sleep 120
            exit 0
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
          limits:
            cpu: "2"
            memory: "2Gi"
        volumeMounts:
        - name: artifacts
          mountPath: /artifacts
      volumes:
      - name: artifacts
        emptyDir: {}
      restartPolicy: Never
EOF

    info "Waiting for scanner pod to start..."
    kubectl wait -n "${SCANNER_NAMESPACE}" --for=condition=Ready pod -l job-name=tls-scanner-job --timeout=300s 2>/dev/null || true

    local pod
    pod=$(kubectl get pods -n "${SCANNER_NAMESPACE}" -l job-name=tls-scanner-job -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "${pod}" ]]; then
        error "Scanner pod not found"
    fi

    info "Tailing scanner logs (timeout ${SCAN_TIMEOUT}s)..."
    local waited=0
    while (( waited < SCAN_TIMEOUT )); do
        if kubectl logs -n "${SCANNER_NAMESPACE}" "${pod}" 2>/dev/null | grep -q "Scanner finished with exit code:"; then
            break
        fi
        sleep 10
        (( waited += 10 ))
    done

    if (( waited >= SCAN_TIMEOUT )); then
        warn "Scan did not complete within ${SCAN_TIMEOUT}s — collecting partial results"
    fi

    info "Collecting results..."
    rm -rf "${OUTPUT_DIR:?}/"*
    kubectl cp "${SCANNER_NAMESPACE}/${pod}:/artifacts/." "${OUTPUT_DIR}/" 2>/dev/null || true

    if [[ -f "${OUTPUT_DIR}/results.csv" ]]; then
        info "Results saved to ${OUTPUT_DIR}/"
        cmd_results
    else
        warn "No results.csv found — check scanner logs:"
        kubectl logs -n "${SCANNER_NAMESPACE}" "${pod}" --tail=50 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# results: parse and display scan results
# ---------------------------------------------------------------------------
cmd_results() {
    if [[ ! -f "${OUTPUT_DIR}/results.csv" ]]; then
        error "No scan results found at ${OUTPUT_DIR}/results.csv — run 'scan' first"
    fi

    echo ""
    echo "============================================"
    echo "  TLS Scan Results Summary"
    echo "============================================"
    echo ""

    # Status=col13, Namespace=col6, PodName=col5, Port=col2, Reason=col14
    echo "--- Status Overview ---"
    if command -v awk &>/dev/null; then
        tail -n +2 "${OUTPUT_DIR}/results.csv" 2>/dev/null | awk -F',' '{print $13}' | sort | uniq -c | sort -rn
    fi
    echo ""

    # Per-namespace breakdown
    echo "--- Per-Namespace Breakdown ---"
    if command -v awk &>/dev/null; then
        tail -n +2 "${OUTPUT_DIR}/results.csv" 2>/dev/null | awk -F',' '{
            ns = $6
            status = $13
            gsub(/^[ \t"]+|[ \t"]+$/, "", ns)
            gsub(/^[ \t"]+|[ \t"]+$/, "", status)
            count[ns][status]++
            namespaces[ns] = 1
        }
        END {
            for (ns in namespaces) {
                printf "\n  %s:\n", ns
                for (s in count[ns]) {
                    printf "    %-20s %d\n", s, count[ns][s]
                }
            }
        }'
    fi
    echo ""

    # Highlight NO_TLS endpoints
    echo "--- Endpoints Without TLS ---"
    if grep -qi "NO_TLS\|no_tls" "${OUTPUT_DIR}/results.csv" 2>/dev/null; then
        grep -i "NO_TLS\|no_tls" "${OUTPUT_DIR}/results.csv"
    else
        echo "  (none found)"
    fi
    echo ""

    # JSON details if available
    if [[ -f "${OUTPUT_DIR}/results.json" ]] && command -v jq &>/dev/null; then
        echo "--- Per-Pod Port Details (from JSON) ---"
        jq -r '
            .ip_results[] |
            "  " + .pod.Namespace + "/" + .pod.Name + ":" +
            ([.port_results[] | "    :" + (.port | tostring) + " " + .status +
              (if .tls_version then " [" + .tls_version + "]" else "" end) +
              (if .reason then " — " + .reason else "" end)] | join("\n"))
        ' "${OUTPUT_DIR}/results.json" 2>/dev/null || echo "  (could not parse JSON results)"
        echo ""
    fi

    echo "Full results: ${OUTPUT_DIR}/results.csv"
    if [[ -f "${OUTPUT_DIR}/results.json" ]]; then
        echo "JSON details: ${OUTPUT_DIR}/results.json"
    fi
    if [[ -f "${OUTPUT_DIR}/scan.log" ]]; then
        echo "Scan log:     ${OUTPUT_DIR}/scan.log"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# cleanup: delete Kind cluster and temp files
# ---------------------------------------------------------------------------
cmd_cleanup() {
    info "Cleaning up..."
    cd "${REPO_ROOT}"

    # Delete scanner RBAC
    kubectl delete clusterrolebinding tls-scanner --ignore-not-found=true 2>/dev/null || true
    kubectl delete clusterrole tls-scanner --ignore-not-found=true 2>/dev/null || true
    kubectl delete namespace "${SCANNER_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true

    # Delete Kind cluster
    make local-cleanup 2>/dev/null || true

    # Remove scanner clone
    if [[ -d "${SCANNER_CLONE_DIR}" ]]; then
        rm -rf "${SCANNER_CLONE_DIR}"
    fi

    info "Cleanup complete. Results preserved in ${OUTPUT_DIR}/"
}

# ---------------------------------------------------------------------------
# all: setup + scan + results
# ---------------------------------------------------------------------------
cmd_all() {
    cmd_setup
    cmd_scan
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  setup      Create Kind cluster with full Kuadrant stack and sample policies
  scan       Build tls-scanner, deploy Job, collect results
  results    Print summary of last scan results
  cleanup    Delete Kind cluster and temp files (preserves results)
  all        Run setup + scan + results

Environment variables:
  SCANNER_IMAGE       Scanner container image tag (default: localhost/tls-scanner:latest)
  SCANNER_NAMESPACE   Namespace for scanner Job (default: tls-scanner)
  NAMESPACE_FILTER    Comma-separated namespaces to scan (default: kuadrant-system,gateway-system,istio-system,cert-manager,mcp-system)
  KIND_CLUSTER_NAME   Kind cluster name (default: kuadrant-local)
  SCANNER_PARALLEL    Concurrent scan threads (default: 2)
  SCAN_TIMEOUT        Max seconds to wait for scan (default: 900)
  MCP_GATEWAY_DIR     Path to mcp-gateway repo (default: ../mcp-gateway relative to kuadrant-operator)
  DNS_OPERATOR_DIR    Path to dns-operator repo (default: ../dns-operator relative to kuadrant-operator)
EOF
}

case "${1:-}" in
    setup)   cmd_setup ;;
    scan)    cmd_scan ;;
    results) cmd_results ;;
    cleanup) cmd_cleanup ;;
    all)     cmd_all ;;
    -h|--help|help) usage ;;
    *)
        usage
        exit 1
        ;;
esac
