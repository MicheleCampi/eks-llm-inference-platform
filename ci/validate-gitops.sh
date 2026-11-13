#!/usr/bin/env bash
# GitOps checks, offline of AWS: chart pins and SHA-256, manifests against the
# CRD schemas of the deployed versions, the wiring between charts, Terraform
# and Alloy, the Alloy configuration validated by Alloy. Then a self-test:
# each negative case must be rejected, for the reason named.
set -uo pipefail
cd "$(dirname "$0")/.."
CI_BIN=${CI_BIN:-$PWD/.ci-bin}
export PATH="$CI_BIN:$CI_BIN/venv/bin:$PATH"
. ci/versions.env
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
for f in lib.sh versions.env; do
  . "$CI_BIN/platform-ci/$f" || { echo "no $CI_BIN/platform-ci/$f: run bash ci/install-tools.sh first" >&2; exit 1; }
done

# Downloads from GitHub fail now and then (timeout on #9): 4 tries, 15/30/60 s apart.
retry() { local n=1 d=15; until "$@"; do [ $n -ge 4 ] && return 1; echo "retry $n/3 in ${d}s: $1 ${2:-}" >&2; sleep $d; n=$((n+1)); d=$((d*2)); done; }

echo "== pins match what ArgoCD deploys"
same pin-eso-chart   "$(yq '.spec.source.targetRevision' gitops/apps/external-secrets.yaml)" "$ESO_CHART_VERSION"
same pin-alloy-chart "$(yq '.spec.source.targetRevision' gitops/apps/alloy.yaml)" "$ALLOY_CHART_VERSION"

echo "== charts and CRDs at the pinned SHA-256"
pull() { # name repo version sha256
  helm pull "$1" --repo "$2" --version "$3" -d "$W" >/dev/null &&
  { [ "$(sha256sum "$W/$1-$3.tgz" | cut -d' ' -f1)" = "$4" ] || { echo "sha256 mismatch: $1-$3"; return 1; }; }
}
check chart-eso   retry pull external-secrets https://charts.external-secrets.io "$ESO_CHART_VERSION" "$ESO_CHART_SHA256"
check chart-alloy retry pull alloy https://grafana.github.io/helm-charts "$ALLOY_CHART_VERSION" "$ALLOY_CHART_SHA256"
check crd-argocd-app retry sh -c "curl -fsSL '$ARGOCD_APP_CRD_URL' -o '$W/argo-raw.yaml' && echo '$ARGOCD_APP_CRD_SHA256  $W/argo-raw.yaml' | sha256sum -c -"

# Every later check needs these inputs: stop here instead of failing in cascade.
[ "$fail" = 0 ] || { echo "RESULT: pinned charts or CRDs unavailable, stopping"; exit 1; }

cat > "$W/served.py" <<'PY'
import sys, yaml
out = []
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "CustomResourceDefinition" and d["metadata"]["name"] in sys.argv[1:]:
        d["spec"]["versions"] = [v for v in d["spec"]["versions"] if v.get("served")]
        out.append(d)
assert len(out) == len(sys.argv[1:]), f"found {len(out)} of {len(sys.argv[1:])} CRDs"
yaml.safe_dump_all(out, sys.stdout)
PY
helm template external-secrets "$W/external-secrets-$ESO_CHART_VERSION.tgz" -n external-secrets > "$W/eso-render.yaml" 2>/dev/null
python3 "$W/served.py" applications.argoproj.io < "$W/argo-raw.yaml" > "$W/crd-argo.yaml"
python3 "$W/served.py" secretstores.external-secrets.io externalsecrets.external-secrets.io < "$W/eso-render.yaml" > "$W/crd-eso.yaml"
for g in argoproj.io:argo external-secrets.io:eso; do
  mkdir -p "$W/schemas/${g%%:*}" && (cd "$W/schemas/${g%%:*}" && python3 "$CI_BIN/openapi2jsonschema.py" "$W/crd-${g##*:}.yaml" >/dev/null)
done
KC=(kubeconform -strict -summary -kubernetes-version "$K8S_SCHEMA_VERSION"
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMA_COMMIT/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
    -schema-location "$W/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

echo "== manifests"
check manifests "${KC[@]}" gitops/root-app.yaml gitops/apps/*.yaml gitops/monitoring/*.yaml
grep -h Summary "$W/manifests.log" | sed 's/^/  /'

echo "== wiring: chart <-> Terraform <-> Alloy"
same eso-sa-matches-pod-identity \
  "$(yq 'select(.kind=="Deployment" and .metadata.name=="external-secrets") | .spec.template.spec.serviceAccountName' "$W/eso-render.yaml")" \
  "$(sed -n -E 's/^  service_account += "(.*)"$/\1/p' modules/eks/eso.tf)"
same secret-name-matches-terraform \
  "$(yq 'select(.kind=="ExternalSecret") | .spec.data[].remoteRef.key' gitops/monitoring/grafana-secret.yaml | sort -u)" \
  "$(sed -n -E 's/^  default += "(.*)"$/\1/p' variables.tf | sed -n 2p)/grafana-cloud-remote-write"
KV=$(yq '.spec.source.targetRevision' gitops/apps/karpenter.yaml)
check karpenter-render sh -c "helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version '$KV' -n kube-system --set settings.clusterName=x > '$W/karpenter-render.yaml' 2>/dev/null"
same karpenter-metrics-port \
  "$(yq 'select(.kind=="Service" and .metadata.name=="karpenter") | .spec.ports[].name' "$W/karpenter-render.yaml")" http-metrics

echo "== alloy: chart renders with our values; configuration validated by alloy"
yq '.spec.source.helm.values' gitops/apps/alloy.yaml > "$W/alloy-values.yaml"
check alloy-render sh -c "helm template alloy '$W/alloy-$ALLOY_CHART_VERSION.tgz' -n monitoring -f '$W/alloy-values.yaml' > '$W/alloy-render.yaml'"
check alloy-render-nonempty test -s "$W/alloy-render.yaml"
check alloy-render-schema "${KC[@]}" "$W/alloy-render.yaml"
yq '.alloy.configMap.content' "$W/alloy-values.yaml" > "$W/alloy.alloy"
ALLOY=(docker run --rm -v "$W:/c:ro" "$ALLOY_IMAGE" validate)
check alloy-config "${ALLOY[@]}" /c/alloy.alloy

echo "== Karpenter alert rules and dashboard"
PROM=(docker run --rm --entrypoint promtool -v "$PWD/observability:/r:ro" -w /r "$PROM_IMAGE")
check rules-check "${PROM[@]}" check rules karpenter-rules.yaml
check rules-test  "${PROM[@]}" test rules karpenter-rules.test.yaml
check dashboard-json python3 -m json.tool observability/karpenter-dashboard.json
check metrics-shipped python3 ci/metrics-shipped.py "$W/alloy.alloy" observability/karpenter-rules.yaml observability/karpenter-dashboard.json
sed -n 1p "$W/metrics-shipped.log" | sed 's/^/  /'

echo "== self-test: each case must be rejected for the reason named"
yq '(select(.kind=="SecretStore") | .apiVersion) = "external-secrets.io/v1beta1"' gitops/monitoring/grafana-secret.yaml > "$W/neg-v1beta1.yaml"
expect_reject neg-unserved-api-version "could not find schema for SecretStore" "${KC[@]}" "$W/neg-v1beta1.yaml"
yq '(select(.kind=="ExternalSecret") | .spec.refreshIntervalz) = "1h"' gitops/monitoring/grafana-secret.yaml > "$W/neg-field.yaml"
expect_reject neg-unknown-field "additional properties 'refreshIntervalz' not allowed" "${KC[@]}" "$W/neg-field.yaml"
sed 's/prometheus.scrape "karpenter"/prometheus.scrapez "karpenter"/' "$W/alloy.alloy" > "$W/neg-alloy.alloy"
cmp -s "$W/alloy.alloy" "$W/neg-alloy.alloy" && { echo "FAIL neg-alloy-component: mutation changed nothing"; fail=1; }
expect_reject neg-alloy-component "validation failed" "${ALLOY[@]}" /c/neg-alloy.alloy

# promtool runs as nobody: the copies must be readable.
mkdir -p "$W/neg-rules" && cp observability/karpenter-rules*.yaml "$W/neg-rules/" && sed -i 's/resource_type="cpu"/resource_type="cpus"/g' "$W/neg-rules/karpenter-rules.yaml" && chmod -R a+rX "$W/neg-rules"
cmp -s observability/karpenter-rules.yaml "$W/neg-rules/karpenter-rules.yaml" && { echo "FAIL neg-rule-wrong-label: mutation changed nothing"; fail=1; }
expect_reject neg-rule-wrong-label "FAILED" docker run --rm --entrypoint promtool -v "$W/neg-rules:/r:ro" -w /r "$PROM_IMAGE" test rules karpenter-rules.test.yaml
sed 's/nodepools_(usage|limit)|//' "$W/alloy.alloy" > "$W/neg-ship.alloy"
cmp -s "$W/alloy.alloy" "$W/neg-ship.alloy" && { echo "FAIL neg-metric-not-shipped: mutation changed nothing"; fail=1; }
expect_reject neg-metric-not-shipped "not shipped by alloy: karpenter_nodepools_limit" python3 ci/metrics-shipped.py "$W/neg-ship.alloy" observability/karpenter-rules.yaml observability/karpenter-dashboard.json
expect_reject neg-chart-sha256 "sha256 mismatch: alloy-$ALLOY_CHART_VERSION" pull alloy https://grafana.github.io/helm-charts "$ALLOY_CHART_VERSION" 0000000000000000000000000000000000000000000000000000000000000000

echo; if [ "$fail" = 0 ]; then echo "RESULT: gitops checks passed"; else echo "RESULT: gitops checks failed"; fi
exit "$fail"
