#!/bin/bash
set -e

REGISTRY="localhost:30003/devnoops"
BASE="/Users/alfaifi/DevNoOps"

# Services that depend on nokit (use replace directive)
NOKIT_SERVICES=(
  nogit noupload noeditor noscan nofind
  noimage noship nocost nogate
  noid nospace nonotify nobill nostatus
  nofix noinfra
)

# Services without nokit dependency
STANDALONE_SERVICES=(nohelm)

echo "=== Building all DevNoOps microservices ==="

# Build standalone services from their own directory
for svc in "${STANDALONE_SERVICES[@]}"; do
  echo ""
  echo ">>> Building $svc (standalone)..."
  docker build -t "${REGISTRY}/${svc}:latest" "${BASE}/${svc}"
  echo "    ✓ ${svc}"
done

# Build nokit-dependent services from parent context
for svc in "${NOKIT_SERVICES[@]}"; do
  echo ""
  echo ">>> Building $svc (with nokit)..."
  docker build \
    -t "${REGISTRY}/${svc}:latest" \
    -f "${BASE}/${svc}/Dockerfile.k8s" \
    "${BASE}"
  echo "    ✓ ${svc}"
done

# Gateway
echo ""
echo ">>> Building gateway (with nokit)..."
docker build \
  -t "${REGISTRY}/gateway:latest" \
  -f "${BASE}/platform/gateway/Dockerfile.k8s" \
  "${BASE}"
echo "    ✓ gateway"

echo ""
echo "=== All images built ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep "$REGISTRY"
