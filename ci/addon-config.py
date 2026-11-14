"""Each EKS add-on configuration (modules/eks/addons/NAME.json) must validate
against the JSON schema AWS publishes for the pinned version
(ci/schemas/NAME-VERSION.json, from describe-addon-configuration), and that
version must be the addon_version in Terraform. A wrong type fails here, not
during a paid apply. Usage: addon-config.py ADDONS_DIR SCHEMAS_DIR TF_FILE..."""
import glob, json, os, re, sys
import jsonschema
addons, schemas, tfs = sys.argv[1], sys.argv[2], sys.argv[3:]
tf = "".join(open(t).read() for t in tfs)
pinned = dict(re.findall(r'addon_name\s*=\s*"([^"]+)"\s*\n\s*addon_version\s*=\s*"([^"]+)"', tf))
errs, n = [], 0
for path in sorted(glob.glob(os.path.join(addons, "*.json"))):
    name = os.path.basename(path)[:-5]
    if name not in pinned:
        errs.append(f"{name}: no pinned addon_version in Terraform"); continue
    schema = os.path.join(schemas, f"{name}-{pinned[name]}.json")
    if not os.path.exists(schema):
        errs.append(f"{name}: no schema for pinned version {pinned[name]}"); continue
    try:
        jsonschema.validate(json.load(open(path)), json.load(open(schema))); n += 1
    except jsonschema.ValidationError as e:
        errs.append(f"{name}: {e.message}")
print(f"{n} add-on configurations valid")
if errs:
    print("invalid: " + "; ".join(errs)); sys.exit(1)
