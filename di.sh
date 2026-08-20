#!/bin/bash
set -e

# The root package's mockito mocks reference types from the local path
# packages (e.g. mallow_api's generated response models). If the root build
# runs before those packages have generated their code, mockito silently
# falls back to `dynamic`, producing invalid_override analyzer errors. So
# build the leaf packages first (in parallel, they are independent of each
# other), then build the root once their generated types exist.
leaf_packages=(
  packages/mallow_api
  packages/jupiter_aggregator
)

build_pkg() {
  local pkg="$1"
  local clean="${2:-}"
  echo "=== Rebuilding DI: $pkg ==="
  (
    cd "$pkg"
    # Leaf packages emit gitignored generated code (e.g. mallow_api's swagger
    # models built from openapi.yaml). build_runner's incremental cache does
    # not reliably invalidate when only the spec's content changes, so a warm
    # CI cache can skip regeneration and leave a stale generated file missing
    # newly-added types. `flutter clean` only clears the root package's cache,
    # not these sub-packages, so wipe the build cache here before regenerating.
    if [ "$clean" = "clean" ]; then
      dart run build_runner clean
    fi
    dart run build_runner build --delete-conflicting-outputs
  )
}

pids=()
for pkg in "${leaf_packages[@]}"; do
  build_pkg "$pkg" clean &
  pids+=($!)
done

failed=0
for pid in "${pids[@]}"; do
  wait "$pid" || failed=1
done

if [ "$failed" -eq 1 ]; then
  echo "=== Failed (leaf packages) ==="
  exit 1
fi

# Root build depends on the leaf packages' generated output above. Clean its
# cache too: injectable's discovery graph can otherwise remain stale on a
# warm CI workspace after a newly annotated dependency is added.
build_pkg "." clean || failed=1

if [ "$failed" -eq 1 ]; then
  echo "=== Failed ==="
  exit 1
fi

echo "=== Done ==="
