# Docker Image Update Automation (shell + Python mailer)

Clones the repositories listed in a CSV file, finds every Dockerfile, checks the registries for newer base-image
versions, optionally updates the Dockerfiles, writes **one report per repository** and e-mails each report to the
repository's POC (To) and developers (CC). Runs on a Jenkins server through the Jenkinsfile.

## Project structure

```
project/
├── Jenkinsfile               # Jenkins pipeline: validate -> docker-update.sh -> email-sent-python.py -> archive/cleanup
├── docker-update.sh          # the ONLY shell script: clone, scan, update, report
├── email-sent-python.py      # the ONLY Python script: To/CC e-mail notifications (standard library only)
├── ReadMe.md
├── config/
│   └── repositories.csv      # repositories + POC e-mail IDs
├── repos/<repository-name>/  # clones (created by the script; emptied by the pipeline after the run)
└── reports/<repository-name>-report-<dd-mon-yyyy>.txt     # e.g. inventory-system-report-23-nov-2026.txt
```

## config/repositories.csv

| Column | Meaning |
|---|---|
| `Repo_Name` | unique name; used for `repos/<name>` and the report file name |
| `Repo_Link` | https clone URL (a local path also works for testing) |
| `POC` | contact name (used in the e-mail greeting) |
| `Email` | **To** addresses (comma, semicolon or space separated) |
| `CC_Email` | **CC** addresses (same format) |
| `Token_Name` | NAME of the environment variable holding the GitHub token, e.g. `GIT_TOKEN`, `GIT_TOKEN2`. Empty = anonymous (public repos) |

Quote a cell that contains commas: `"dev1@x.com, dev2@x.com"`. An address in both columns is kept in To only; duplicates
and invalid addresses are dropped. One row per line (no multi-line cells). Lines starting with `#` are ignored.

## Prerequisites (Jenkins agent / local machine)

`bash` 4.3+, `git`, `curl`, `jq`, `awk`, `sed`, `base64`, `python3` 3.8+ (mailer only). `docker` is optional
(`DOCKER_CHECK=true`). Network access to GitHub, `hub.docker.com` and the registries your Dockerfiles use.

## What `docker-update.sh` does

1. Reads `config/repositories.csv`; picks the token from the environment variable named in `Token_Name`.
2. Picks the branch: first existing of **dev → development → develop → main**, otherwise the default branch.
3. Shallow-clones into `repos/<name>/` (token sent as an HTTP header, never in a URL or command line).
4. Finds all Dockerfiles (`Dockerfile`, `Dockerfile.*`, `*.Dockerfile`, depth ≤ 4) and detects technologies
   (Node.js, React, Angular, Vue.js, Python, Java Maven/Gradle, Go, .NET, Ruby, PHP).
5. For every `FROM image:tag` asks Docker Hub or the OCI registry (GHCR, Quay, MCR, ...) for tags and selects
   - **Same Major** – newest stable tag in the same release line with the same variant (`-slim`, `-alpine` ...),
   - **New Major** – newest stable tag of a later major line (never applied automatically; status `REQUIRES_VALIDATION`;
     Node.js only proposes even/LTS majors). Pre-releases (rc, beta, ...) and tags with another variant are ignored.
6. With `DRY_RUN=false` rewrites the Same-Major tags in place, checks the result (FROM count unchanged, new tag present,
   optional `docker buildx build --check`) and **reverts** the file if the check fails.
7. With `COMMIT_PUSH=true` commits to branch `docker-image-update/<timestamp>` and pushes it; `CREATE_PR=true` also opens a pull request.
8. Writes `reports/<name>-report-<dd-mon-yyyy>.txt`: header, technology summary, update-details table, validation
   table, notes and the summary counts. A repository that cannot be cloned still gets a report (status `FAILED` + reason).

Not handled (reported as `SKIPPED`, update manually): images using `ARG` variables, digest-pinned images, untagged
images, non-version tags (`bookworm`, `latest`), private registries without anonymous access.
New-major remarks say only whether a matching technology was found; declared runtime versions (e.g. `engines`) are not evaluated.

### Settings (environment variables, all optional)

| Variable | Default | Meaning |
|---|---|---|
| `STRATEGY` | `both` | `same_major`, `new_major` or `both` |
| `DRY_RUN` | `true` | `true` = report only, Dockerfiles never modified |
| `COMMIT_PUSH` / `CREATE_PR` | `false` | push a branch / open a PR (need `DRY_RUN=false`, write-capable token) |
| `TEST_MODE` | `false` | no push, no PR, no e-mail |
| `REPOSITORIES` | all | comma separated `Repo_Name` filter |
| `BRANCH_PRIORITY` | `dev development develop main` | branch search order |
| `DOCKER_CHECK` | `false` | also run `docker buildx build --check` on modified Dockerfiles |
| `MAX_DEPTH`, `MAX_TAG_PAGES` | `4`, `10` | Dockerfile search depth / registry pages (100 tags each) |
| `CONFIG_FILE`, `REPOS_DIR`, `REPORTS_DIR` | project folders | override locations |

Exit code: `0` ok, `1` some repositories failed (reports still written), `2` setup/config error.

## What `email-sent-python.py` does

For each row of the CSV it sends today's `reports/<name>-report-<date>.txt` **in one e-mail**: To = `Email`, CC = `CC_Email`,
the full report in the body (monospace HTML + plain text) and the `.txt` attached. Repositories without a report today are skipped.

| Variable | Meaning |
|---|---|
| `SMTP_SERVER`, `SMTP_PORT` (587), `SMTP_USERNAME`, `SMTP_PASSWORD`, `EMAIL_FROM` | mail server (secrets: environment only) |
| `SMTP_SECURITY` | `auto` (465 = SSL, else STARTTLS when offered), `ssl`, `starttls`, `none` |
| `TEST_MODE=true` / `--dry-run` | send nothing, print recipients and subject |
| `REPOSITORIES`, `REPORT_DATE` | filter / report date (`dd-mon-yyyy`, default today) |

## Run locally

```bash
export GIT_TOKEN=ghp_xxx GIT_TOKEN2=ghp_yyy        # names used in Token_Name
./docker-update.sh                                  # report only (DRY_RUN=true)
TEST_MODE=true python3 email-sent-python.py         # preview the e-mails
SMTP_SERVER=smtp.example.com EMAIL_FROM=bot@example.com SMTP_USERNAME=u SMTP_PASSWORD=p python3 email-sent-python.py
DRY_RUN=false COMMIT_PUSH=true REPOSITORIES=inventory-system ./docker-update.sh   # apply + push one repo
```

## Jenkins setup

1. Install the prerequisites on the agent and create **Secret text** credentials for the tokens plus a
   **Username with password** credential `smtp-credentials`.
2. Edit the credential-ID map at the top of the `Jenkinsfile` (`GIT_TOKEN: 'github-token-1'`, ...).
3. Optional global/job environment variables: `SMTP_SERVER`, `SMTP_PORT`, `EMAIL_FROM`.
4. New *Pipeline* job → *Pipeline script from SCM* → Script Path `Jenkinsfile`.

Parameters: `REPOSITORIES`, `STRATEGY`, `DRY_RUN` (default true), `COMMIT_PUSH`, `CREATE_PR`, `TEST_MODE` (default true), `SEND_EMAIL`.
Start with the defaults; switch `TEST_MODE` and `DRY_RUN` off only when the reports look right. Exit code 1 → build UNSTABLE.
Reports are archived as build artifacts and `repos/` is emptied after every run.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `token variable GIT_TOKEN2 is not set` | map the credential in the Jenkinsfile; the name must equal `Token_Name` |
| `authentication failed` / `repository not found` | token lacks access to that repository |
| Row `SKIPPED ... requires credentials` | private registry image - not checked |
| `report not found` in the mailer | docker-update.sh did not run today for that repo (or `REPORT_DATE` differs) |
| Docker Hub rate limit | the script retries with back-off; run less often or lower `MAX_TAG_PAGES` |
