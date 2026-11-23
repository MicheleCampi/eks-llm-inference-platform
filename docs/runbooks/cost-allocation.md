# Cost per live session: the Session cost allocation tag

Why: on 2026-11-22 four sessions (A-021 to A-024) ran on the same day, and
Cost Explorer's daily granularity could not split them: the real cost of each
had to be estimated. Hourly granularity is a paid Cost Explorer feature, and
this project uses no paid resources. A tag per session splits them for free.

## What carries the tag

| Resource | How it gets `Session` |
|---|---|
| Everything Terraform creates (EKS, NAT gateway, EIP, VPC, SQS, log group, secrets, budget, ...) | `providers.tf` `default_tags`, from the required `session` input of `apply.yml` and `destroy.yml` |
| The system node group's instances, volumes and ENIs | launch template `tag_specifications` (`modules/eks/main.tf`), the same map |
| Karpenter nodes, their volumes and ENIs | EC2NodeClass `spec.tags`, patched by ApplicationSet `karpenter-nodes` from the label of the Argo CD cluster secret (`scripts/label-session.sh`, live.md step 3) |

CI: `ci/check-cost-tags.py` (patch applied to every EC2NodeClass, fail closed
without the label), the `karpenter-session-render` kustomize render, and
`tests/session_tag.tftest.hcl` (default_tags, malformed values refused).

Not tagged, so not split by session: costs that AWS does not attribute to a
tagged resource (some data transfer, and credits, which have no tags). Cost
Explorer shows them as "No tag key: Session"; read them by day, as before.

## One-time activation (operator)

Cost allocation tags are a setting of the account, not of a session, so they
live in `bootstrap/ci-identity/cost-allocation-tags.tf`, which no destroy
touches. Until 2026-11-23 `Project` was activated in the cluster stack, and
deleting `aws_ce_cost_allocation_tag` sets the tag Inactive: every destroy
deactivated it until the next apply.

AWS accepts a tag key only after it has seen it on a resource, up to 24 hours
after the first resource with it. So, in this order, with administrator
credentials, as for every bootstrap change:

1. Now, before the next session: keep `Project` active for good.

       terraform -chdir=bootstrap/ci-identity init && terraform -chdir=bootstrap/ci-identity apply -var 'cost_allocation_tags=["Project"]'

2. The first session with this release: apply with `-f session=A-NNN`
   (live.md step 2).
3. One day after that session: activate `Session` too (the default list).

       terraform -chdir=bootstrap/ci-identity apply

   If it fails with a tag key not found, AWS has not seen the key yet: run it
   again later.
4. Then backfill, so the activation applies to the whole month and not only
   from today (both tags; one backfill request per 24 hours): Billing and
   Cost Management, Cost allocation tags, "Backfill tags", from
   2026-11-01. The same from the CLI (API `StartCostAllocationTagBackfill`;
   Cost Explorer API requests may be billed 0.01 USD each, the console is
   free):

       aws ce start-cost-allocation-tag-backfill --backfill-from 2026-11-01T00:00:00Z

Console equivalent of steps 1 and 3: Cost allocation tags, User-defined:
select the key, Activate. Terraform's `aws_ce_cost_allocation_tag` makes the
same few API calls that every apply of the cluster stack made until now.

## Reading the cost of a session

Cost Explorer (console, free): Date range covering the session, Granularity
Daily, Group by **Tag: Session**, Filters **Record type: Usage**. Each A-NNN is
one session; the credits that net it to zero are not tagged (see above), so
read them by day as before. The Cost Explorer API costs 0.01 USD per request:
use the console.
