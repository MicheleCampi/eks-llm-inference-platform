"""Every job that can assume an AWS role (id-token: write) masks the account id
from its first log line. ::add-mask:: inside a step is too late: the runner
prints the step's env header (AWS_ROLE_ARN, from a repo variable, holds the
account id) before the step runs. A secret referenced by the job is masked by
the runner from the start of the job. Required, per job:
  1. job env AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}
  2. first step fails if that secret is missing or not 12 digits (an empty
     secret masks nothing)
  3. each step that sets AWS_ROLE_ARN fails if the assumed role's account is
     not that secret (a wrong secret masks the wrong number)
Usage: check-account-mask.py WORKFLOW..."""
import sys, yaml
REF = "${{ secrets.AWS_ACCOUNT_ID }}"
GUARD = '[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]'
MATCH = '[ "$acct" = "$AWS_ACCOUNT_ID" ]'

def oidc(perms):
    return perms == "write-all" or (isinstance(perms, dict) and perms.get("id-token") == "write")

bad, n = [], 0
for f in sys.argv[1:]:
    wf = yaml.safe_load(open(f))
    for name, job in (wf.get("jobs") or {}).items():
        if not oidc(job.get("permissions", wf.get("permissions"))):
            continue
        n += 1
        where = f"{f}:{name}"
        if (job.get("env") or {}).get("AWS_ACCOUNT_ID") != REF:
            bad.append(f"{where}: job env AWS_ACCOUNT_ID is not {REF}")
        steps = job.get("steps") or []
        if not steps or GUARD not in (steps[0].get("run") or ""):
            bad.append(f"{where}: first step does not check secret AWS_ACCOUNT_ID")
        for s in steps:
            if "AWS_ROLE_ARN" in (s.get("env") or {}) and MATCH not in (s.get("run") or ""):
                bad.append(f"{where}: step '{s.get('name')}' sets AWS_ROLE_ARN without checking the account against AWS_ACCOUNT_ID")
if bad:
    sys.exit("FAIL: account id not masked from job start:\n  " + "\n  ".join(bad))
if n == 0:
    sys.exit("FAIL: no job with id-token: write found (wrong files?)")
print(f"account id mask OK: {n} AWS jobs mask it from job start")
