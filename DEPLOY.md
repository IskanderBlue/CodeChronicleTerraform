# CodeChronicle Terraform Deployment Guide

## Architecture

```
envs/prod/main.tf
  ├── modules/network      → VPC + subnet + firewall (443 from Cloudflare, 22 from admin)
  ├── modules/neon          → Neon Postgres project + role + db
  ├── modules/secrets       → GCP Secret Manager (DB URL, Django key, CF origin cert/key)
  ├── modules/compute       → GCE VM (e2-micro) + static IP + service account + startup.sh
  └── modules/cloudflare    → Proxied A records (app + www) + TLS strict
                              + R2 bucket + edge Worker for asset serving
```

Data flow: `neon.connection_uri → secrets → compute.secret_names`, `network → compute`, `compute.public_ip → cloudflare`, `subdomains → compute (ALLOWED_HOSTS) + cloudflare (A records, asset routes)`.

Assets (the CCM-mirrored `documents/`, `amended/`, `laws/` image trees) live in
Cloudflare R2 and are served at the edge by a Worker bound to the bucket, on the
same `app.<domain>` / `www.<domain>` origin the app uses — so the root-relative
`<img src="/laws/...">` paths in stored HTML resolve without rewriting. The
running app holds no R2 credentials; only the upload side does.

## Manual Setup Required

### Sign up / accounts needed

1. **GCP project** — create one (or use existing), note the project ID
2. **Neon account** — sign up at [neon.tech](https://neon.tech), generate an API key from Account Settings
3. **Cloudflare account** — add your domain, then:
   - Note your **Account ID** (Cloudflare dashboard → any domain → right sidebar, or the URL `dash.cloudflare.com/<account-id>`). Needed for the `cloudflare_account_id` variable.
   - Generate an API token with these permissions:
     - **`Zone: DNS: Edit`**
     - **`Zone: SSL and Certificates: Edit`**
     - **`Zone: Workers Routes: Edit`** — binds the asset Worker to URL patterns (routes are zone-scoped, separate from the script).
     - **`Account: Workers Scripts: Edit`** — uploads the asset Worker.
     - **`Account: Workers R2 Storage: Edit`** — creates/manages the R2 bucket.
     - **`Zone: Zone WAF: Edit`** — the custom rule that challenges crawlers on the print routes (`cloudflare_ruleset.firewall_custom`).
     - **`Account: Turnstile: Read`** — the plan reads the Turnstile widget. Without this permission, every plan fails with a 403. Change it to Edit only when an apply must change the widget.

     Note the split: the *script* and *bucket* are Account-scoped, but the *routes* are Zone-scoped. Missing the routes permission surfaces as a `403 Authentication error` on `workers/routes` only — the bucket and script create fine.
4. **Cloudflare Origin CA cert** — in Cloudflare dashboard → SSL/TLS → Origin Server → Create Certificate; save the cert and private key. **Include a wildcard hostname** (`*.<domain>` alongside `<domain>`) so the single cert covers both `app.` and `www.`. The default Origin CA form pre-fills `<domain>, *.<domain>` — keep it.
5. **Cloudflare R2 S3 access keys** (for publishing assets, not for the running app):
   - These are **not** the same as the Cloudflare API token Terraform uses (step 3). That token is a Bearer token; R2 S3 keys are an **Access Key ID + Secret Access Key** pair that boto3/the S3 API needs. Adding scopes to the Terraform token does **not** produce them — they only come from R2's own token flow. The generic *My Profile → API Tokens* page is the wrong place.
   - **Enable R2 first.** Left nav → **R2 Object Storage** → **Enable R2** / **Purchase R2**. The R2 token UI does not appear until R2 is activated. The free tier requires this opt-in (and a payment method on file) but does not charge under its limits.
   - Then go to the **R2 token manager** (a separate page from the generic API tokens): `https://dash.cloudflare.com/<account-id>/r2/api-tokens`, or R2 → **Overview** → **Manage API Tokens** → **Create API token** → **Object Read & Write**.
   - Record the **Access Key ID** and **Secret Access Key** immediately — the secret is shown only once. These go in the `.env` of whoever runs `sync_images --backend r2` (see "Publishing assets to R2" below).
   - The bucket itself is created by Terraform — you do **not** pre-create it.

### GCP APIs to enable

- Compute Engine API
- Secret Manager API

### Variables to provide

Non-sensitive values — safe to put in `prod.tfvars`:

| Variable | Source |
|---|---|
| `gcp_project_id` | Your GCP project ID |
| `gcp_region` | GCP region (default: `us-central1`) |
| `gcp_zone` | GCP zone (default: `us-central1-a`) |
| `domain` | Your domain on Cloudflare |
| `subdomains` | Hosts the app serves on (default: `["app", "www"]`). Drives DNS records, asset Worker routes, and `ALLOWED_HOSTS`. |
| `cloudflare_account_id` | Cloudflare Account ID (owns the R2 bucket + Worker). Not secret. |
| `app_image` | Docker image for CodeChronicle |
| `machine_type` | VM size (default: `e2-micro`) |
| `admin_ssh_cidrs` | Your IP as `["x.x.x.x/32"]` |

### Pre-create secrets in GCP Secret Manager

Before the first deploy, create these secrets once:

```bash
DJANGO_KEY=$(python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())")

gcloud secrets create django_secret_key --project=YOUR_PROJECT_ID
echo -n "$DJANGO_KEY" | gcloud secrets versions add django_secret_key --data-file=- --project=YOUR_PROJECT_ID

gcloud secrets create cf_origin_cert --project=YOUR_PROJECT_ID
gcloud secrets versions add cf_origin_cert --data-file=origin.pem --project=YOUR_PROJECT_ID

gcloud secrets create cf_origin_key --project=YOUR_PROJECT_ID
gcloud secrets versions add cf_origin_key --data-file=origin-key.pem --project=YOUR_PROJECT_ID
```

Set provider credentials as shell environment variables (not Secret Manager).
These are session-scoped — set them in the same shell you run `terraform` from,
right before `plan`/`apply`; they vanish when the session closes (intended for
secrets). Both are required for any apply: the `neon` provider can't read its
state without its key, even when you're only changing Cloudflare resources.

Bash / Linux / macOS:

```bash
export TF_VAR_cloudflare_api_token="YOUR_TOKEN"
export TF_VAR_neon_api_key="YOUR_KEY"
export TF_VAR_asset_signing_key=$(gcloud secrets versions access latest --secret=app_runtime_secrets | python -c "import sys,json;print(json.load(sys.stdin)['ASSET_SIGNING_KEY'])")
```

PowerShell (Windows):

```powershell
$env:TF_VAR_cloudflare_api_token = "YOUR_TOKEN"
$env:TF_VAR_neon_api_key = "YOUR_KEY"
$env:TF_VAR_asset_signing_key = (gcloud secrets versions access latest --secret=app_runtime_secrets | ConvertFrom-Json).ASSET_SIGNING_KEY
```

The asset-signing key is read, not typed. Django and the Cloudflare Worker must
hold the same value. The `app_runtime_secrets` bundle is the one copy, and both
sides read that copy. A second copy is a second thing to keep in step, and a
mismatch makes every page scan answer 403.

App/runtime secrets remain in GCP Secret Manager.

### Database roles and grants

Terraform creates three Neon roles, and it grants them nothing.

| Role | Use |
|---|---|
| `codechroniclenet_app` | Owns every table. Runs `migrate`. Serves no request. |
| `cc_app` | The role the application connects as. |
| `cc_ro` | SELECT only, for a read-only session. |

The application connects through the pooler host. The owner connects to the
direct host, because the pooler runs PgBouncer in transaction mode.
`modules/neon/outputs.tf` builds both strings, and
`envs/prod/main.tf` writes them to `database_url` and `database_url_owner`.

⚠️ A new project needs the grants as well. `envs/prod` speaks to the Neon API
and runs no SQL, so a role it creates in an empty project has no privileges.
The application starts, connects, and fails on the first query.

`envs/prod-grants` applies the grants. It is a separate root module, and the
ordinary deploy never runs it.

```bash
terraform -chdir=envs/prod-grants init
terraform -chdir=envs/prod-grants apply
```

It reads the host, the database name and the role names from `envs/prod`'s
state, so run it **after** the first `envs/prod` apply. It needs no variables
and no credentials of its own.

Run it in two conditions:

1. After a rebuild from an empty Neon project. Apply it once.
2. As a privilege audit, at any time. `plan` that reports no changes is the
   statement that nobody has widened a role.

⚠️ `terraform destroy` in `envs/prod-grants` revokes every privilege and stops
the site.

The grants stay in a separate directory for two reasons. A `plan` there opens
a database connection, and the ordinary deploy must not need one. A variable
that turns the grants on and off is also dangerous: an apply with the variable
off destroys the grant resources, and Terraform destroys a grant with a
`REVOKE`.

## Deploying

1. Copy `envs/prod/prod.tfvars.example` to `envs/prod/prod.tfvars` and fill in non-sensitive values.

2. Run Terraform directly from `envs/prod`:

```bash
terraform -chdir=envs/prod init
terraform -chdir=envs/prod plan -var-file=prod.tfvars
terraform -chdir=envs/prod apply -var-file=prod.tfvars
```

If you changed providers/modules since the last run (e.g. first time adding the
R2 + Worker resources), re-run `init` so the new provider features are available.

### First apply: R2 asset Worker

`terraform validate` confirms the `cloudflare_workers_script` *schema*, but only
`apply` confirms Cloudflare accepts the **inline ES-module upload** (the Worker's
`content` + `main_module = "asset-proxy.js"`). Watch this resource on the first
apply:

- **If it applies cleanly** — nothing to do; the `ASSETS` R2 binding and the
  `app.`/`www.` × `{documents,amended,laws}` routes come up with it.
- **If it balks on the inline module** — switch the script in
  `modules/cloudflare/main.tf` from inline `content` to a hashed file reference:

  ```hcl
  # content     = file("${path.module}/asset-proxy.js")   # replace this line
  content_file   = "${path.module}/asset-proxy.js"
  content_sha256 = filesha256("${path.module}/asset-proxy.js")
  ```

  `main_module` stays the same. Re-run `apply`. (Same bytes, just uploaded as a
  file part instead of inline — some provider/API versions require this form.)

The R2 bucket and Worker routes have no other manual steps; the only credential
the Worker uses is the R2 binding, injected by Cloudflare at the edge.

### Important: COS host firewall behavior

Some Container-Optimized OS boots can have a restrictive host firewall (`iptables` `INPUT DROP`).  
This can cause Cloudflare `522` even when GCP VPC firewall rules are correct.

The compute startup script now applies an idempotent host-level allow for HTTPS:

```bash
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT
```

If you update infrastructure and still see `522`, confirm this rule exists on the VM:

```bash
gcloud compute ssh codechroniclenet-vm --zone=us-central1-a --command="sudo iptables -S INPUT"
```

### Custom hostnames (app. and www.)

`subdomains` (default `["app", "www"]`) is the single source of truth for which
hosts the app answers on. From it Terraform derives:

- one proxied **A record per subdomain** (all pointing at the VM's static IP),
- the **asset Worker routes** (`<subdomain>.<domain>/{documents,amended,laws}/*`), and
- the VM's **`ALLOWED_HOSTS`** (apex + every subdomain + `localhost`).

To add or remove a host later, edit `subdomains` in `prod.tfvars` and re-apply —
DNS, routes, and `ALLOWED_HOSTS` all move together. (The existing `app` record is
preserved across the single→list change via a `moved` block, so it is re-keyed in
state, not destroyed.)

> ⚠️ **`ALLOWED_HOSTS` only updates on VM boot.** The startup script writes the
> VM's `.env` at boot time. Changing `subdomains` updates the instance's
> startup-script *metadata* in place, but a **running** VM keeps its old
> `ALLOWED_HOSTS` until it reboots, so Django will reject the new host with
> `DisallowedHost (400)`. After applying a `subdomains` change, reboot the VM:
>
> ```bash
> gcloud compute instances reset codechroniclenet-vm --zone=us-central1-a
> ```
>
> (`reset` re-runs the startup script. A normal app redeploy does *not* — it only
> restarts the container with the existing `.env`.)

After the new host resolves, update Django's Site record so allauth builds email
links against the canonical host — see Post-Deploy step 3.

## Post-Deploy

1. SSH into the VM and run migrations:

```bash
docker exec -it <container> python manage.py migrate
```

2. Seed code maps:

```bash
docker exec -it <container> python manage.py load_maps
```

3. Set the Django **Site** domain to the canonical host (used by allauth for
   email links). Run once after the `www` host is live:

```bash
docker exec -it <container> python manage.py shell -c "from django.contrib.sites.models import Site; Site.objects.update_or_create(id=1, defaults={'domain': 'www.<domain>', 'name': 'CodeChronicle'})"
```

4. Smoke test the health endpoint on **both** hosts:

```bash
curl -sf https://app.<domain>/api/health
curl -sf https://www.<domain>/api/health
```

5. After publishing assets to R2 (next section), confirm one resolves through the
   edge Worker on each host — expect `200` and `cf-worker`/`cache` headers:

```bash
curl -sI https://www.<domain>/laws/images/<some-known-key>.webp
```

## Loading Data from Your Laptop

`load_code_metadata` and `load_maps` are pure data-loading commands — they read local files and write to the database via Django ORM, with no VM or Docker dependencies. You can run them directly against the Neon database from your laptop.

1. Get the Neon connection string from the Neon dashboard or GCP Secret Manager (`database_url` secret).

2. Run from the CodeChronicle repo:

```bash
cd ../CodeChronicle
set DATABASE_URL=postgresql://codechroniclenet_app:<password>@<host>/codechroniclenet?sslmode=require
set DJANGO_SETTINGS_MODULE=code_chronicle.settings.production

python manage.py load_code_metadata --source config/metadata.json
python manage.py load_maps --source ../CodeChronicle-Mapping/maps
```

No SSH or Docker needed. Migrations (`manage.py migrate`) can also be run this way.

## Publishing Assets to R2

The CCM-mirrored image trees (`documents/`, `elaws/`, `amended/`, `laws/`) are
served in production from the Cloudflare R2 bucket created by Terraform
(`module.cloudflare.asset_bucket_name`, default `codechronicle-assets-prod`).
Uploading is a laptop-run step — like `load_maps`, it reads local CCM build
output and writes to the destination, with no VM or Docker dependency.

**Prerequisite:** `terraform apply` has created the bucket + Worker, and you have
R2 S3 access keys (see Manual Setup step 5). The running app never needs these
keys — only this upload step does.

1. Put the R2 credentials in `../CodeChronicle/.env` (or export them):

```bash
R2_ACCOUNT_ID=<your-cloudflare-account-id>
R2_BUCKET=codechronicle-assets-prod
R2_ACCESS_KEY_ID=<r2-access-key-id>
R2_SECRET_ACCESS_KEY=<r2-secret-access-key>
# R2_ENDPOINT_URL is optional; defaults to https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com
```

2. Upload from the CodeChronicle repo:

```bash
cd ../CodeChronicle
python manage.py sync_images --backend r2
```

> ⚠️ Do not give one `--source` root. CCM keeps the trees in two places:
> `laws/` is a build output, and `documents/` and `elaws/` are intermediates.
> A single root publishes `laws/` only, and the command still reports success.
> This is what left production with 96 of the 532 objects that it needs. The
> default covers both roots. `--source` is repeatable if you must set it.

The command prints one `Mirroring <prefix>/ from <root>` line for each prefix
that it finds, and a warning for each prefix that no root holds. Read those
lines. They are the only signal that a tree is absent.

The sync is idempotent and content-addressed: reruns only upload changed objects
(checked via `HEAD` + a stored `sha256` metadata field), and `laws/` paths
registered in `RegulationAsset` are hash-verified. Add `--strict-manifest` to
fail the run on any missing or mismatched registered asset.

The default `--backend local` copies into `ASSET_ROOT` on disk instead, which is
the dev path (assets served by Django/nginx locally).

## Updating the App (without Terraform)

Normal app deploys should now happen from `../CodeChronicle/.github/workflows/publish.yml`.

The automated path is:

1. Push to `main` in `../CodeChronicle`.
2. GitHub Actions runs Django checks and tests.
3. GitHub Actions pushes `ghcr.io/iskanderblue/codechroniclenet:latest` and `ghcr.io/iskanderblue/codechroniclenet:<git-sha>`.
4. GitHub Actions authenticates to GCP with OIDC.
5. GitHub Actions connects to `codechroniclenet-vm` through IAP and runs the VM-local deploy script.
6. The new container starts, runs `migrate` and `collectstatic`, and serves traffic.
7. GitHub Actions smoke-tests `https://app.<domain>/api/health`.

No `terraform apply` is needed unless you're changing infrastructure (VM size, firewall rules, secrets, etc.).

### Manual fallback

If the workflow is unavailable, you can still trigger the same reset-less deploy path manually:

```bash
gcloud compute ssh codechroniclenet-vm --zone=us-central1-a --tunnel-through-iap --command="sudo bash /home/codechroniclenet/deploy-web.sh ghcr.io/iskanderblue/codechroniclenet:latest"
```

To roll back manually, pass a previously published SHA tag instead of `latest`.
