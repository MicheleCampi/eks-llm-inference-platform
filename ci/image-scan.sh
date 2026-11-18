#!/usr/bin/env bash
# Vulnerability scan of every image the platform runs (list made by
# ci/validate-gitops.sh with IMAGES_OUT). Policy:
#   - CRITICAL with a fixed version available fails the job. Fix: bump the
#     pin (our images) or the chart (upstream images), or accept it in
#     ci/trivyignore-images.yaml with a reason and an expiry.
#   - HIGH with a fix is reported in the job summary, not blocking: tracked,
#     fixed at the next chart upgrade.
#   - Unfixed CVEs are not counted: nothing to act on until a fix exists.
# Not covered: EKS add-on images (vpc-cni, metrics-server, Pod Identity),
# which AWS manages and patches.
# Usage: bash ci/image-scan.sh IMAGES_FILE
set -uo pipefail
cd "$(dirname "$0")/.."
TRIVY="${CI_BIN:-$PWD/.ci-bin}/trivy"
LIST=${1:?images file}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}
CACHE=$(mktemp -d); trap 'rm -rf "$CACHE"' EXIT
fail=0
{
  echo "| Image | CRITICAL (fixable) | HIGH (fixable) | Result |"
  echo "|---|---|---|---|"
} >> "$SUMMARY"
while read -r img; do
  [ -n "$img" ] || continue
  out="$CACHE/report.json"
  if ! "$TRIVY" image -q --cache-dir "$CACHE/db" --scanners vuln --ignore-unfixed \
      --severity CRITICAL,HIGH --ignorefile ci/trivyignore-images.yaml \
      --format json --output "$out" "$img"; then
    echo "| \`$img\` | ? | ? | scan error |" >> "$SUMMARY"; fail=1; continue
  fi
  read -r crit high < <(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = [x for r in d.get("Results") or [] for x in r.get("Vulnerabilities") or []]
print(sum(x["Severity"] == "CRITICAL" for x in v), sum(x["Severity"] == "HIGH" for x in v))' "$out")
  if [ "$crit" -gt 0 ]; then
    res="FAIL"; fail=1
    "$TRIVY" image -q --cache-dir "$CACHE/db" --skip-db-update --scanners vuln --ignore-unfixed \
      --severity CRITICAL --ignorefile ci/trivyignore-images.yaml "$img"
  else
    res="pass"
  fi
  echo "| \`${img%@*}\` | $crit | $high | $res |" >> "$SUMMARY"
  echo "$res $img (critical $crit, high $high)"
done < "$LIST"
[ "$fail" = 0 ] && echo "IMAGE SCAN PASS" || echo "IMAGE SCAN FAIL: fixable CRITICAL found (see table)"
exit "$fail"
