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
same pin-ksm-chart "$(yq '.spec.source.targetRevision' gitops/apps/kube-state-metrics.yaml)" "$KSM_CHART_VERSION"
same pin-kyverno-chart "$(yq '.spec.source.targetRevision' gitops/apps/kyverno.yaml)" "$KYVERNO_CHART_VERSION"

echo "== charts and CRDs at the pinned SHA-256"
pull() { # name repo version sha256
  helm pull "$1" --repo "$2" --version "$3" -d "$W" >/dev/null &&
  { [ "$(sha256sum "$W/$1-$3.tgz" | cut -d' ' -f1)" = "$4" ] || { echo "sha256 mismatch: $1-$3"; return 1; }; }
}
check chart-eso   retry pull external-secrets https://charts.external-secrets.io "$ESO_CHART_VERSION" "$ESO_CHART_SHA256"
check chart-alloy retry pull alloy https://grafana.github.io/helm-charts "$ALLOY_CHART_VERSION" "$ALLOY_CHART_SHA256"
check chart-ksm retry pull kube-state-metrics https://prometheus-community.github.io/helm-charts "$KSM_CHART_VERSION" "$KSM_CHART_SHA256"
check chart-kyverno retry pull kyverno https://kyverno.github.io/kyverno/ "$KYVERNO_CHART_VERSION" "$KYVERNO_CHART_SHA256"
check kyverno-cli retry sh -c "curl -fsSL '$KYVERNO_CLI_URL' -o '$W/kyv.tgz' && echo '$KYVERNO_CLI_SHA256  $W/kyv.tgz' | sha256sum -c - && tar xzf '$W/kyv.tgz' -C '$W' kyverno"
check crd-argocd-app retry sh -c "curl -fsSL '$ARGOCD_APP_CRD_URL' -o '$W/argo-raw.yaml' && echo '$ARGOCD_APP_CRD_SHA256  $W/argo-raw.yaml' | sha256sum -c -"
check crd-argocd-project retry sh -c "curl -fsSL '$ARGOCD_PROJECT_CRD_URL' -o '$W/argo-proj-raw.yaml' && echo '$ARGOCD_PROJECT_CRD_SHA256  $W/argo-proj-raw.yaml' | sha256sum -c -"

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
{ cat "$W/argo-raw.yaml"; echo "---"; cat "$W/argo-proj-raw.yaml"; } | python3 "$W/served.py" applications.argoproj.io appprojects.argoproj.io > "$W/crd-argo.yaml"
python3 "$W/served.py" secretstores.external-secrets.io externalsecrets.external-secrets.io < "$W/eso-render.yaml" > "$W/crd-eso.yaml"
helm template kyverno "$W/kyverno-$KYVERNO_CHART_VERSION.tgz" -n kyverno 2>/dev/null | tee "$W/kyverno-render.yaml" | python3 "$W/served.py" validatingpolicies.policies.kyverno.io > "$W/crd-kyv.yaml"
for g in argoproj.io:argo external-secrets.io:eso policies.kyverno.io:kyv; do
  mkdir -p "$W/schemas/${g%%:*}" && (cd "$W/schemas/${g%%:*}" && python3 "$CI_BIN/openapi2jsonschema.py" "$W/crd-${g##*:}.yaml" >/dev/null)
done
KC=(kubeconform -strict -summary -kubernetes-version "$K8S_SCHEMA_VERSION"
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMA_COMMIT/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
    -schema-location "$W/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

echo "== manifests"
check manifests "${KC[@]}" gitops/root-app.yaml gitops/apps/*.yaml gitops/monitoring/*.yaml gitops/policies/*.yaml
grep -h Summary "$W/manifests.log" | sed 's/^/  /'

echo "== wiring: chart <-> Terraform <-> Alloy"
same eso-sa-matches-pod-identity \
  "$(yq 'select(.kind=="Deployment" and .metadata.name=="external-secrets") | .spec.template.spec.serviceAccountName' "$W/eso-render.yaml")" \
  "$(sed -n -E 's/^  service_account += "(.*)"$/\1/p' modules/eks/eso.tf)"
same secret-name-matches-terraform \
  "$(yq 'select(.kind=="ExternalSecret") | .spec.data[].remoteRef.key' gitops/monitoring/grafana-secret.yaml | sort -u)" \
  "$(sed -n -E 's/^  default += "(.*)"$/\1/p' variables.tf | sed -n 2p)/grafana-cloud-remote-write"
KV=$(yq '.spec.source.targetRevision' gitops/apps/karpenter.yaml)
check karpenter-render retry sh -c "helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version '$KV' -n kube-system --set settings.clusterName=x --include-crds > '$W/karpenter-render.yaml' 2>/dev/null"
same karpenter-metrics-port \
  "$(yq 'select(.kind=="Service" and .metadata.name=="karpenter") | .spec.ports[].name' "$W/karpenter-render.yaml")" http-metrics

echo "== Karpenter pools: schema of the pinned CRDs, then the invariants a schema cannot express"
# CRDs from the chart Argo CD deploys (--include-crds above). CEL rules
# (x-kubernetes-validations) are not evaluated here: only the API server does.
python3 "$W/served.py" nodepools.karpenter.sh < "$W/karpenter-render.yaml" > "$W/crd-np.yaml"
python3 "$W/served.py" ec2nodeclasses.karpenter.k8s.aws < "$W/karpenter-render.yaml" > "$W/crd-nc.yaml"
for g in karpenter.sh:np karpenter.k8s.aws:nc; do
  mkdir -p "$W/schemas/${g%%:*}" && (cd "$W/schemas/${g%%:*}" && python3 "$CI_BIN/openapi2jsonschema.py" "$W/crd-${g##*:}.yaml" >/dev/null)
done
check karpenter-schema "${KC[@]}" gitops/karpenter/*.yaml
grep -h Summary "$W/karpenter-schema.log" | sed 's/^/  /'
check nodepools "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-nodepools.py gitops/karpenter/*.yaml
sed -n '$p' "$W/nodepools.log" | sed 's/^/  /'

echo "== alloy: chart renders with our values; configuration validated by alloy"
yq '.spec.source.helm.values' gitops/apps/alloy.yaml > "$W/alloy-values.yaml"
check alloy-render sh -c "helm template alloy '$W/alloy-$ALLOY_CHART_VERSION.tgz' -n monitoring -f '$W/alloy-values.yaml' > '$W/alloy-render.yaml'"
check alloy-render-nonempty test -s "$W/alloy-render.yaml"
check alloy-render-schema "${KC[@]}" "$W/alloy-render.yaml"
yq '.spec.source.helm.values' gitops/apps/kube-state-metrics.yaml > "$W/ksm-values.yaml"
check ksm-render sh -c "helm template ksm '$W/kube-state-metrics-$KSM_CHART_VERSION.tgz' -n monitoring -f '$W/ksm-values.yaml' > '$W/ksm-render.yaml'"
check ksm-render-nonempty test -s "$W/ksm-render.yaml"
check ksm-render-schema "${KC[@]}" "$W/ksm-render.yaml"
yq '.alloy.configMap.content' "$W/alloy-values.yaml" > "$W/alloy.alloy"
ALLOY=(docker run --rm -v "$W:/c:ro" "$ALLOY_IMAGE" validate)
check alloy-config "${ALLOY[@]}" /c/alloy.alloy

echo "== Karpenter alert rules and dashboard"
PROM=(docker run --rm --entrypoint promtool -v "$PWD/observability:/r:ro" -w /r "$PROM_IMAGE")
check rules-check "${PROM[@]}" check rules karpenter-rules.yaml
check rules-test  "${PROM[@]}" test rules karpenter-rules.test.yaml
check dashboard-json sh -c "python3 -m json.tool observability/karpenter-dashboard.json >/dev/null && python3 -m json.tool observability/rightsizing-dashboard.json >/dev/null"
check metrics-shipped python3 ci/metrics-shipped.py "$W/alloy.alloy" observability/karpenter-rules.yaml observability/karpenter-dashboard.json observability/rightsizing-dashboard.json
# mimirtool syncs the file to namespace karpenter-rules, derived from the file
# name (pkg/mimirtool/rules/parser.go): an explicit namespace would escape it.
check rules-mimirtool-lint mimirtool rules lint --dry-run observability/karpenter-rules.yaml
check rules-no-namespace sh -c "! grep -nE '^namespace:' observability/karpenter-rules.yaml || { echo 'namespace: set, sync uses the file name'; exit 1; }"
sed -n 1p "$W/metrics-shipped.log" | sed 's/^/  /'

echo "== Kyverno policies: the platform complies, rendered with the values ArgoCD deploys"
# require-pdb reads PodDisruptionBudgets from the cluster (resource.List): the
# context file stands in for it, with the one PDB tests/live/inflate.yaml creates.
KY=("$W/kyverno" apply gitops/policies/ --context-file ci/fixtures/kyverno/pdb-context.yaml)
yq '.spec.source.helm.valuesObject' gitops/apps/external-secrets.yaml > "$W/eso-values.yaml"
helm template external-secrets "$W/external-secrets-$ESO_CHART_VERSION.tgz" -n external-secrets -f "$W/eso-values.yaml" > "$W/eso-deployed.yaml"
OV=$(yq '.spec.source.targetRevision' gitops/apps/vllm-coldstart-operator.yaml)
check operator-src retry sh -c "rm -rf '$W/op' && git clone -q --depth 1 --branch '$OV' https://github.com/MicheleCampi/vllm-coldstart-operator.git '$W/op'"
# example.enabled=false, as the Application's helm parameters set it.
helm template vcso "$W/op/chart" -n vllm-operator-system --set example.enabled=false > "$W/op-deployed.yaml"
check platform-complies "${KY[@]}" --resource "$W/eso-deployed.yaml" --resource "$W/alloy-render.yaml" --resource "$W/op-deployed.yaml" --resource "$W/ksm-render.yaml"
grep -h '^pass' "$W/platform-complies.log" | sed 's/^/  /'
check exempt-namespace-ignored "${KY[@]}" --resource ci/fixtures/kyverno/exempt.yaml
grep -q 'pass: 0, fail: 0' "$W/exempt-namespace-ignored.log" || { echo "FAIL exempt-namespace-ignored: the kube-system pod was evaluated"; fail=1; }
# karpenter-config-from-git: Argo CD may apply every NodePool and EC2NodeClass in Git.
KPOL=(--resource gitops/karpenter/ec2nodeclass.yaml --resource gitops/karpenter/ec2nodeclass-gpu.yaml --resource gitops/karpenter/nodepool-general.yaml --resource gitops/karpenter/nodepool-gpu.yaml)
check karpenter-config-argocd "${KY[@]}" -u ci/fixtures/kyverno/userinfo-argocd.yaml "${KPOL[@]}"
grep -q 'pass: 4, fail: 0' "$W/karpenter-config-argocd.log" || { echo "FAIL karpenter-config-argocd: expected 4 passes"; fail=1; }

echo "== EKS add-on configurations against the AWS schemas"
check addon-config "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/addon-config.py modules/eks/addons ci/schemas modules/eks/addons.tf modules/eks/karpenter.tf
sed -n 1p "$W/addon-config.log" | sed 's/^/  /'
echo "== tenancy: each team confined to its namespace, capped by a platform-owned quota"
check tenancy "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-tenancy.py .
sed -n '$p' "$W/tenancy.log" | sed 's/^/  /'
check cost-tags "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-cost-tags.py gitops/karpenter/ec2nodeclass.yaml
check iam-boundary "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-iam-boundary.py modules
mkdir -p "$W/neg-iam" && printf 'resource "aws_iam_role" "x" {\n  name = "llm-inference-x"\n}\n' > "$W/neg-iam/main.tf"
TRIVY=("${CI_BIN:-$PWD/.ci-bin}/trivy" config -q --cache-dir "$W/trivy-cache" --skip-check-update --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore)
# ci/fixtures: deliberately bad manifests for negative cases; ci/karpenter: upstream reference copy. Neither is deployed.
check trivy-config "${TRIVY[@]}" --skip-dirs ci/fixtures --skip-dirs gitops/argocd/upstream --skip-files ci/karpenter/cloudformation-v1.15.1.yaml .
# Charts as Argo CD deploys them: app values, no helm test hooks (Argo CD v3.4.14 skips them).
mkdir -p "$W/charts" "$W/neg-chart"
yq '.spec.source.helm.valuesObject' gitops/apps/kyverno.yaml > "$W/kyv-values.yaml"
yq '.spec.source.helm.valuesObject' gitops/apps/karpenter.yaml > "$W/karp-values.yaml"
helm template kyverno "$W/kyverno-$KYVERNO_CHART_VERSION.tgz" -n kyverno --skip-tests -f "$W/kyv-values.yaml" > "$W/charts/kyverno.yaml"
check karpenter-deployed-render retry sh -c "helm template karpenter oci://public.ecr.aws/karpenter/karpenter --version '$KV' -n kube-system -f '$W/karp-values.yaml' > '$W/charts/karpenter.yaml' 2>/dev/null"
cp "$W/eso-deployed.yaml" "$W/charts/eso.yaml"; cp "$W/alloy-render.yaml" "$W/charts/alloy.yaml"; cp "$W/ksm-render.yaml" "$W/charts/ksm.yaml"; cp "$W/op-deployed.yaml" "$W/charts/operator.yaml"
TRIVY_CH=("${CI_BIN:-$PWD/.ci-bin}/trivy" config -q --cache-dir "$W/trivy-cache" --skip-check-update --severity HIGH,CRITICAL --exit-code 1 --ignorefile ci/trivyignore-charts.yaml)
check argocd-upstream-sha sh -c "echo '$ARGOCD_INSTALL_SHA256  gitops/argocd/upstream/install-v3.4.14.yaml' | sha256sum -c -"
check argocd-overlay-build sh -c "kustomize build gitops/argocd > '$W/charts/argocd.yaml'"
# Dex (SSO, unused) stays out of the overlay: no object named argocd-dex-server*
# and no dex image. The server keeps an optional reference to the
# argocd-dex-server-tls secret, so match object names exactly.
check argocd-no-dex sh -c "! grep -Eq '^  name: argocd-dex-server(-network-policy)?\$|image: .*dexidp' '$W/charts/argocd.yaml'"
check trivy-charts "${TRIVY_CH[@]}" "$W/charts"
# Every image the platform runs, from the charts as deployed and the live
# test workloads (VllmService spec.image included): the input of
# ci/image-scan.sh. IMAGES_OUT keeps the list for that job.
yq -N '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' "$W"/charts/*.yaml tests/live/*.yaml tests/gameday/*.yaml | sort -u > "$W/images.txt"
check images-listed test "$(wc -l < "$W/images.txt")" -ge 8
sed 's/^/  /' "$W/images.txt"
[ -n "${IMAGES_OUT:-}" ] && cp "$W/images.txt" "$IMAGES_OUT"
# Live #4: Argo CD adds PreDelete finalizers to a child Application with
# pre-delete hooks (kyverno), so root must ignore exactly those.
check root-finalizers "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-root-finalizers.py gitops/root-app.yaml "$W"/charts/*.yaml
sed -n '1p' "$W/root-finalizers.log" | sed 's/^/  /'
yq 'del(.spec.ignoreDifferences)' gitops/root-app.yaml > "$W/neg-root.yaml"
expect_reject neg-root-finalizers "root does not ignore pre-delete-finalizer" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-root-finalizers.py "$W/neg-root.yaml" "$W"/charts/*.yaml
{ cat gitops/argocd/upstream/install-v3.4.14.yaml; echo "# tampered"; } > "$W/argocd-tampered.yaml"
helm template kyverno "$W/kyverno-$KYVERNO_CHART_VERSION.tgz" -n kyverno --skip-tests > "$W/neg-chart/kyverno.yaml"
echo "== AppProject platform: every cluster-scoped kind its apps create is whitelisted"
OPV=$(yq '.spec.source.targetRevision' gitops/apps/vllm-coldstart-operator.yaml)
check operator-render sh -c "rm -rf '$W/op' && git clone -q --depth 1 -b '$OPV' https://github.com/MicheleCampi/vllm-coldstart-operator '$W/op' && helm template vcso '$W/op/chart' -n vllm-operator-system --set example.enabled=false --include-crds > '$W/op-render.yaml'"
PK=("$W/eso-render.yaml" "$W/kyverno-render.yaml" "$W/karpenter-render.yaml" "$W/alloy-render.yaml" "$W/ksm-render.yaml" "$W/op-render.yaml" gitops/karpenter/*.yaml gitops/policies/*.yaml gitops/monitoring/*.yaml gitops/apps/*.yaml)
check project-kinds "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-project-kinds.py gitops/apps/projects.yaml platform "${PK[@]}"
check release-pin "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-release-pin.py https://github.com/MicheleCampi/eks-llm-inference-platform gitops/root-app.yaml gitops/apps/*.yaml
# The live test workload must pass the same admission policies, or the live session finds out with the meter running.
check live-workload-complies "${KY[@]}" --resource tests/live/inflate.yaml
# The live #3 inference workload: a VllmService valid for the operator release
# Argo CD deploys (CRD from its chart at that tag), in a namespace the
# policies accept. The pod itself is built by the operator, at run time.
python3 "$W/served.py" vllmservices.inference.michelecampi.dev < "$W/op/chart/crds/crd.yaml" > "$W/crd-vllm.yaml"
mkdir -p "$W/schemas/inference.michelecampi.dev" && (cd "$W/schemas/inference.michelecampi.dev" && python3 "$CI_BIN/openapi2jsonschema.py" "$W/crd-vllm.yaml" >/dev/null)
check live-inference-schema "${KC[@]}" tests/live/inference-cpu.yaml
check live-inference-complies "${KY[@]}" --resource tests/live/inference-cpu.yaml
check live-imds-probe-complies "${KY[@]}" --resource tests/live/imds-probe.yaml
# Live #3 without FIS: the injected Spot warning must parse as Karpenter
# v1.15.1 parses it (version 0, source aws.ec2, that detail-type, the
# instance in detail.instance-id), or Karpenter drops it as unknown.
check live-spot-message sh -c "bash tests/live/spot-interruption.sh --print i-0123456789abcdef0 | python3 -c 'import json,sys; m=json.load(sys.stdin); assert (m[\"version\"],m[\"source\"],m[\"detail-type\"])==(\"0\",\"aws.ec2\",\"EC2 Spot Instance Interruption Warning\"), m; assert m[\"detail\"][\"instance-id\"]==\"i-0123456789abcdef0\" and m[\"resources\"][0].endswith(\"/i-0123456789abcdef0\"), m'"
yq 'select(.kind=="VllmService") | .spec.gpuz = 0' tests/live/inference-cpu.yaml > "$W/neg-vllm.yaml"
expect_reject neg-vllmservice-unknown-field "additional properties 'gpuz' not allowed" "${KC[@]}" "$W/neg-vllm.yaml"
# Scaled as in live #3 (5 replicas): allowed, because its PDB exists.
sed 's/replicas: 0/replicas: 5/' tests/live/inflate.yaml > "$W/inflate-5.yaml"
cmp -s tests/live/inflate.yaml "$W/inflate-5.yaml" && { echo "FAIL live-workload-5-replicas: mutation changed nothing"; fail=1; }
check live-workload-5-replicas "${KY[@]}" --resource "$W/inflate-5.yaml"
grep -q 'fail: 0, warn: 0, error: 0' "$W/live-workload-5-replicas.log" || { echo "FAIL live-workload-5-replicas: not every policy passed"; fail=1; }
# Game day #1 (docs/gameday/): probe and PDB valid and admitted; the model at
# 2 replicas admitted only because the PDB of tests/gameday/model.yaml selects its pods
# (the operator v0.13.0 creates no PDB). The SLI script against its fixture.
check gameday-schema "${KC[@]}" tests/gameday/probe.yaml tests/gameday/model.yaml
check gameday-probe-complies "${KY[@]}" --resource tests/gameday/probe.yaml
check gameday-model-complies "${KY[@]}" --resource tests/gameday/model.yaml
check gameday-model-2-replicas "${KY[@]}" --resource ci/fixtures/kyverno/vllm-2-replicas.yaml
grep -q 'pass: 4, fail: 0, warn: 0, error: 0' "$W/gameday-model-2-replicas.log" || { echo "FAIL gameday-model-2-replicas: require-pdb not evaluated or not passed"; fail=1; }
sed 's/app: qwen-0-5b-cpu, app.kubernetes/app: other, app.kubernetes/g' ci/fixtures/kyverno/vllm-2-replicas.yaml > "$W/neg-gameday-nopdb.yaml"
cmp -s ci/fixtures/kyverno/vllm-2-replicas.yaml "$W/neg-gameday-nopdb.yaml" && { echo "FAIL neg-gameday-nopdb: mutation changed nothing"; fail=1; }
expect_reject neg-gameday-nopdb "needs a PodDisruptionBudget" "${KY[@]}" --resource "$W/neg-gameday-nopdb.yaml"
check gameday-sli python3 -I ci/test-gameday-sli.py
echo "== self-test: each case must be rejected for the reason named"
sed 's/targetRevision: v[0-9.]*/targetRevision: main/' gitops/apps/policies.yaml > "$W/neg-pin.yaml"
expect_reject neg-release-pin-main "not a release tag" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-release-pin.py https://github.com/MicheleCampi/eks-llm-inference-platform gitops/root-app.yaml "$W/neg-pin.yaml"
printf 'apiVersion: scheduling.k8s.io/v1\nkind: PriorityClass\nmetadata:\n  name: neg\nvalue: 1000\n' > "$W/neg-pc.yaml"
grep -v 'kind: NodePool}' gitops/apps/projects.yaml > "$W/neg-projects.yaml"
# Custom kind: its scope comes from the Karpenter CRD, not from the built-in list.
expect_reject neg-project-crd-kind "karpenter.sh/NodePool" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-project-kinds.py "$W/neg-projects.yaml" platform "${PK[@]}"
expect_reject neg-project-kind-not-allowed "scheduling.k8s.io/PriorityClass" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-project-kinds.py gitops/apps/projects.yaml platform "${PK[@]}" "$W/neg-pc.yaml"
# Destinations: Argo CD refuses an app outside its project only at sync time (PR #34).
check app-destinations "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-app-destinations.py gitops/apps/*.yaml gitops/root-app.yaml
sed -n '$p' "$W/app-destinations.log" | sed 's/^/  /'
sed 's/^    namespace: monitoring$/    namespace: default/' gitops/apps/monitoring.yaml > "$W/neg-dest.yaml"
cmp -s gitops/apps/monitoring.yaml "$W/neg-dest.yaml" && { echo "FAIL neg-app-destination: mutation changed nothing"; fail=1; }
expect_reject neg-app-destination "not allowed by project platform" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-app-destinations.py gitops/apps/projects.yaml "$W/neg-dest.yaml"
sed 's/^  project: platform$/  project: default/' gitops/apps/monitoring.yaml > "$W/neg-dest-default.yaml"
cmp -s gitops/apps/monitoring.yaml "$W/neg-dest-default.yaml" && { echo "FAIL neg-app-project-default: mutation changed nothing"; fail=1; }
expect_reject neg-app-project-default "uses project default" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-app-destinations.py gitops/apps/projects.yaml "$W/neg-dest-default.yaml"
mkdir -p "$W/neg-tf" && printf 'resource "aws_subnet" "p" {\n  vpc_id                  = "vpc-1"\n  cidr_block              = "10.0.0.0/24"\n  map_public_ip_on_launch = true\n}\n' > "$W/neg-tf/main.tf"
expect_reject neg-trivy-public-ip "AWS-0164" "${TRIVY[@]}" "$W/neg-tf"
expect_reject neg-trivy-chart-no-podsecuritycontext "KSV-0118" "${TRIVY_CH[@]}" "$W/neg-chart"
expect_reject neg-argocd-upstream-tampered "FAILED" sh -c "echo '$ARGOCD_INSTALL_SHA256  $W/argocd-tampered.yaml' | sha256sum -c -"
expect_reject neg-iam-role-without-boundary "without permissions_boundary" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-iam-boundary.py "$W/neg-iam"
# Pools: a GPU-capable pool without the taint, a pool without a cost cap, an
# unknown field, IMDSv1 allowed. Each mutation must change the file.
mutate() { sed "$1" "$2" > "$3"; cmp -s "$2" "$3" && { echo "FAIL $4: mutation changed nothing"; fail=1; }; }
NP=(gitops/karpenter/ec2nodeclass.yaml gitops/karpenter/ec2nodeclass-gpu.yaml gitops/karpenter/nodepool-general.yaml)
mutate '/nvidia.com\/gpu, value/d' gitops/karpenter/nodepool-gpu.yaml "$W/neg-gpu-taint.yaml" neg-gpu-pool-untainted
expect_reject neg-gpu-pool-untainted "can launch GPU instances without the nvidia.com/gpu NoSchedule taint" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-nodepools.py "${NP[@]}" "$W/neg-gpu-taint.yaml"
mutate 's/t3.small\]/t3.small, g6.xlarge]/' gitops/karpenter/nodepool-general.yaml "$W/neg-general-gpu.yaml" neg-general-allows-gpu
expect_reject neg-general-allows-gpu "NodePool general: can launch GPU instances" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-nodepools.py gitops/karpenter/ec2nodeclass*.yaml gitops/karpenter/nodepool-gpu.yaml "$W/neg-general-gpu.yaml"
mutate '/^  limits:/,/^    cpu:/d' gitops/karpenter/nodepool-general.yaml "$W/neg-no-limits.yaml" neg-pool-no-limits
expect_reject neg-pool-no-limits "NodePool general: no spec.limits" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-nodepools.py gitops/karpenter/ec2nodeclass*.yaml gitops/karpenter/nodepool-gpu.yaml "$W/neg-no-limits.yaml"
mutate '/terminationGracePeriod:/d' gitops/karpenter/nodepool-general.yaml "$W/neg-no-tgp.yaml" neg-pool-no-tgp
expect_reject neg-pool-no-tgp "no terminationGracePeriod" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-nodepools.py gitops/karpenter/ec2nodeclass*.yaml gitops/karpenter/nodepool-gpu.yaml "$W/neg-no-tgp.yaml"
mutate 's/httpTokens: required/httpTokens: optional/' gitops/karpenter/ec2nodeclass-gpu.yaml "$W/neg-imdsv1.yaml" neg-nodeclass-imdsv1
expect_reject neg-nodeclass-imdsv1 "EC2NodeClass gpu: IMDSv2 must be required" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-nodepools.py gitops/karpenter/ec2nodeclass.yaml gitops/karpenter/nodepool*.yaml "$W/neg-imdsv1.yaml"
mutate 's/terminationGracePeriod: 1h/terminationGracePeriodz: 1h/' gitops/karpenter/nodepool-general.yaml "$W/neg-np-field.yaml" neg-nodepool-unknown-field
expect_reject neg-nodepool-unknown-field "terminationGracePeriodz" "${KC[@]}" "$W/neg-np-field.yaml"
grep -v '    Project:' gitops/karpenter/ec2nodeclass.yaml > "$W/neg-nodeclass.yaml"
expect_reject neg-nodeclass-no-cost-tag "tag Project is None" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-cost-tags.py "$W/neg-nodeclass.yaml"
sed 's/^  description: Team namespaces/  descriptionTypo: Team namespaces/' gitops/apps/projects.yaml > "$W/neg-project.yaml"
expect_reject neg-appproject-unknown-field "descriptionTypo" "${KC[@]}" "$W/neg-project.yaml"
rm -rf "$W/neg-ten" && mkdir -p "$W/neg-ten" && cp -r gitops "$W/neg-ten/"
sed -i 's/resources: \["resourcequotas", "limitranges"\]/resources: ["resourcequotas", "limitranges"]\n  verbs: ["get", "list", "watch", "patch"]\n- apiGroups: [""]\n  resources: ["configmaps"]/' "$W/neg-ten/gitops/tenants/demo/rbac.yaml"
expect_reject neg-team-edits-quota "may change limitranges, resourcequotas" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/check-tenancy.py "$W/neg-ten"
mkdir -p "$W/neg-addons-type" "$W/neg-addons-version"
echo '{"enableNetworkPolicy": true}' > "$W/neg-addons-type/vpc-cni.json"
expect_reject neg-addon-boolean "is not one of" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/addon-config.py "$W/neg-addons-type" ci/schemas modules/eks/addons.tf
cp modules/eks/addons/vpc-cni.json "$W/neg-addons-version/" && sed 's/v1.22.4-eksbuild.14/v1.22.4-eksbuild.99/' modules/eks/addons.tf > "$W/neg-addons.tf"
expect_reject neg-addon-version "no schema for pinned version v1.22.4-eksbuild.99" "${CI_BIN:-$PWD/.ci-bin}/venv/bin/python" ci/addon-config.py "$W/neg-addons-version" ci/schemas "$W/neg-addons.tf"
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
{ echo 'namespace: other'; cat observability/karpenter-rules.yaml; } > "$W/neg-ns-rules.yaml"
expect_reject neg-rules-namespace "namespace: set, sync uses the file name" sh -c "! grep -nE '^namespace:' '$W/neg-ns-rules.yaml' || { echo 'namespace: set, sync uses the file name'; exit 1; }"
sed 's/ > on (nodepool)/ >>/' observability/karpenter-rules.yaml | sed 's/>= on (nodepool)/>= >/' > "$W/neg-lint-rules.yaml"
cmp -s observability/karpenter-rules.yaml "$W/neg-lint-rules.yaml" && { echo "FAIL neg-rules-lint: mutation changed nothing"; fail=1; }
expect_reject neg-rules-lint "parse error" mimirtool rules lint --dry-run "$W/neg-lint-rules.yaml"
expect_reject neg-policy-latest "every image needs a version tag or a digest" "${KY[@]}" --resource ci/fixtures/kyverno/latest.yaml
expect_reject neg-policy-requests "must declare resources.requests.cpu" "${KY[@]}" --resource ci/fixtures/kyverno/no-requests.yaml
expect_reject neg-policy-pdb-missing "needs a PodDisruptionBudget" "${KY[@]}" --resource ci/fixtures/kyverno/pdb-missing.yaml
expect_reject neg-policy-privileged "privileged containers are not allowed" "${KY[@]}" --resource ci/fixtures/kyverno/privileged.yaml
expect_reject neg-policy-team-mismatch "must equal the namespace name" "${KY[@]}" --resource ci/fixtures/kyverno/team-label-mismatch.yaml
expect_reject neg-policy-team-missing "namespaces must carry" "${KY[@]}" --resource ci/fixtures/kyverno/team-label-missing.yaml
expect_reject neg-karpenter-config-by-hand "denied for kubernetes-admin" "${KY[@]}" -u ci/fixtures/kyverno/userinfo-human.yaml "${KPOL[@]}"
expect_reject neg-platform-without-requests "require-requests -> resource external-secrets/Deployment/external-secrets" "${KY[@]}" --resource "$W/eso-render.yaml"
expect_reject neg-chart-sha256 "sha256 mismatch: alloy-$ALLOY_CHART_VERSION" pull alloy https://grafana.github.io/helm-charts "$ALLOY_CHART_VERSION" 0000000000000000000000000000000000000000000000000000000000000000

echo; if [ "$fail" = 0 ]; then echo "RESULT: gitops checks passed"; else echo "RESULT: gitops checks failed"; fi
exit "$fail"
