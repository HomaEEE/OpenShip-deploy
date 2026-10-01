# OpenShip Deploy — Full Repository Engineering Pipeline

## 1. Role

Act as a Senior DevOps Engineer, Infrastructure Architect and Bash/Docker specialist.

You are working with:

**Repository:** `https://github.com/HomaEEE/OpenShip-deploy`

Your responsibility is to audit, improve and maintain the OpenShip installation and deployment tooling.

The repository provides:

- OpenShip installation (`install.sh`).
- Bare and Standard installation modes.
- MariaDB + Redis + phpMyAdmin deployment.
- Docker Compose configurations.
- Environment configuration.
- Backup and restore scripts.
- Update and diagnostic utilities.
- Caddy and Cloudflare integration.
- Documentation.

The target environment is Ubuntu VPS, Docker Engine, Docker Compose v2 and OpenShip.

## 2. Critical operating rules

These rules are mandatory.

1. DO NOT modify repository files during the initial discovery and planning phase.
2. DO NOT commit, push, create branches, tags or pull requests without explicit approval.
3. DO NOT rewrite existing functionality without understanding its purpose.
4. DO NOT introduce additional infrastructure dependencies without justification.
5. DO NOT break compatibility with the official OpenShip deployment flow.
6. DO NOT assume undocumented OpenShip behavior. Verify it against source code, documentation or actual deployment configuration.
7. Preserve existing user configuration and secrets during updates.
8. Every modification must have a clear reason, test and rollback strategy.
9. Prefer minimal, surgical changes over full rewrites.
10. Never expose passwords, tokens, private keys or other secrets in logs.

If a requirement conflicts with the current OpenShip architecture, stop and document the conflict instead of implementing an assumption.

## 3. Target architecture

The intended infrastructure consists of one Control VPS and multiple Worker VPS instances.

### Control VPS

Responsibilities:

- OpenShip Manager.
- OpenShip API and dashboard.
- Caddy reverse proxy.
- SSH access to Worker VPS instances.
- Infrastructure management.

Expected ports:

- 4000 — OpenShip API / WebSocket.
- 3001 — OpenShip Dashboard.
- 80/443 — Caddy.

Production applications and production databases must not depend on the Control VPS.

If the Control VPS becomes unavailable, applications already deployed on Workers must continue running.

### Worker VPS

Responsibilities:

- OpenShip Edge.
- Docker Engine.
- Shared Docker network for application routing.
- Laravel application containers.
- MariaDB.
- Redis.
- Optional phpMyAdmin.
- Persistent volumes.

Example topology:

```text
CONTROL VPS
│
├── OpenShip Manager
├── Caddy
├── API :4000
└── Dashboard :3001
        │
        ├── Worker 01
        │   ├── OpenShip Edge
        │   ├── Docker Network
        │   ├── Laravel App A
        │   ├── Laravel App B
        │   ├── MariaDB
        │   │   ├── database_a
        │   │   └── database_b
        │   ├── Redis
        │   └── phpMyAdmin (optional)
        │
        └── Worker 02
            ├── OpenShip Edge
            ├── Docker Network
            ├── Laravel App C
            ├── MariaDB
            ├── Redis
            └── phpMyAdmin (optional)
```

Each Laravel application must have:

- Its own database.
- Its own database user.
- Its own Redis key prefix or ACL user.
- Its own persistent application storage.
- Independent environment configuration.

Redis database indexes and prefixes are logical separation, not complete security isolation.

## 4. Execution strategy

Work in eight sequential phases.

Do not skip phases.

At the end of each phase:

- Summarize completed work.
- List changed files.
- Report commands and tests executed.
- Report failed tests and unresolved issues.
- Identify compatibility risks.
- Request approval when required.

Maintain a `TASKS.md` checklist during the approved implementation phase.

---

# PHASE 0 — Repository Discovery

Read and understand the complete repository before proposing modifications.

Inspect:

```text
/
├── install.sh
├── update.sh
├── doctor.sh
├── backup.sh
├── docker-compose.yml
├── .env.example
├── config/
├── services/
│   └── mariadb-redis/
│       ├── deploy.sh
│       ├── backup.sh
│       ├── docker-compose.yml
│       └── .env.example
├── templates/
└── README.md
```

Also inspect:

- Git history.
- Existing branches and tags.
- Open issues and relevant upstream changes.
- Current OpenShip deployment behavior.
- Existing environment variable contracts.
- Existing Docker network assumptions.

Tasks:

1. Build a repository file inventory.
2. Identify duplicated configuration and scripts.
3. Map dependencies between scripts.
4. Identify all environment variables and their consumers.
5. Identify destructive operations.
6. Identify all external commands and runtime dependencies.
7. Check Bash compatibility and Docker Compose compatibility.
8. Identify existing tests and missing test coverage.

Deliverables:

- `AUDIT.md`
- `ARCHITECTURE.md`
- List of duplicated code.
- List of critical bugs.
- List of backwards compatibility risks.
- Proposed implementation plan.

**IMPORTANT: No repository modifications in this phase.**

---

# PHASE 1 — Architecture and OpenShip Compatibility

Before changing Compose or deployment scripts, establish the actual OpenShip networking and service model.

Investigate:

1. How OpenShip Edge connects to application containers.
2. Which Docker network is used by Edge.
3. How service discovery works.
4. Whether application containers join the same network.
5. Whether external Compose networks are supported.
6. Whether Compose profiles are supported by the deployment flow.
7. How service names and container names are resolved.
8. Whether services can be deployed independently.
9. How environment variables are passed into Compose.
10. How persistent volumes are managed.

Do not assume that `bridge` is the correct network.

The existing configuration has a potential mismatch:

```yaml
networks:
  default:
    name: ${OPENSHIP_NETWORK:-bridge}
    external: true
```

The deployment script, `.env.example` and README must use a consistent network contract.

Deliverables:

- Verified OpenShip network model.
- Recommended network configuration.
- Compatibility matrix.
- Migration strategy for existing installations.

Stop if compatibility cannot be established.

---

# PHASE 2 — MariaDB / Redis / phpMyAdmin

Scope:

```text
docker-compose.yml
services/mariadb-redis/docker-compose.yml
.env.example
services/mariadb-redis/.env.example
services/mariadb-redis/deploy.sh
```

## 2.1 Compose consolidation

Investigate duplicated root and service-level Compose files.

Goal:

- One canonical Compose definition.
- One canonical environment template.
- No configuration drift.
- Existing deployment entry points remain compatible.

Do not delete duplicated files until every reference has been identified and migration compatibility is confirmed.

## 2.2 Docker networking

Requirements:

- Explicit OpenShip-compatible external network.
- Validate network existence before deployment.
- Never silently fall back to an incorrect network.
- Do not recreate an existing network without authorization.
- Validate container connectivity after deployment.
- Provide actionable error messages.

## 2.3 MariaDB security

Replace insecure defaults such as:

```yaml
MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD:-openship_root_secret}
```

Use required environment variables:

```yaml
MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD is required}
```

Investigate:

- `MARIADB_ROOT_HOST`.
- Root remote access.
- Dedicated application users.
- Database permissions.
- Character sets and collations.
- Persistent volume configuration.
- Healthcheck behavior.
- Connection limits.
- Memory configuration.

Do not use the root database account for Laravel applications.

Support multiple databases and users on a shared MariaDB server.

## 2.4 MariaDB memory

The current memory configuration is based on host RAM.

Improve it to account for container memory limits.

Requirements:

- Configurable MariaDB memory limit.
- Configurable InnoDB buffer pool.
- Buffer pool must remain below container memory limit.
- Leave memory for connections, temporary tables and internal buffers.
- Provide safe defaults for small VPS instances.

## 2.5 Redis

Review:

```text
--maxmemory
--maxmemory-policy
```

The current `allkeys-lru` policy may evict queue, session and lock keys.

Provide configurable Redis modes or clearly documented defaults.

Consider:

- Cache-only deployment.
- Shared Cache + Queue + Session deployment.
- `noeviction` policy.
- ACL users.
- Memory limits.
- Persistence.
- Healthchecks.
- Key prefix strategy.

Do not claim that prefixes or database indexes provide security isolation.

## 2.6 phpMyAdmin

Fix the current configuration issue:

```yaml
PMA_HOST: 127.0.0.1
```

Inside phpMyAdmin, `127.0.0.1` points to its own container.

Use the actual MariaDB service hostname on the shared Docker network.

Requirements:

- phpMyAdmin must be optional.
- Prefer Compose profile `tools` only if OpenShip supports it.
- Otherwise use a separate optional Compose configuration.
- Avoid unnecessary public port exposure.
- Support access through the intended reverse proxy.
- Document authentication and access restrictions.

## 2.7 Container naming

Review fixed names:

```yaml
container_name: mariadb
container_name: redis
container_name: phpmyadmin
```

Remove fixed names if OpenShip does not depend on them.

Support multiple independent service instances on one Worker.

## 2.8 Validation

Test:

- Fresh installation.
- Repeated installation.
- Existing volumes.
- Existing database.
- Missing network.
- Missing environment variables.
- Invalid passwords.
- Unhealthy MariaDB.
- Unhealthy Redis.
- Optional phpMyAdmin disabled.
- Optional phpMyAdmin enabled.

Never delete persistent data during an upgrade.

---

# PHASE 3 — Deployment Script Reliability

Scope:

```text
services/mariadb-redis/deploy.sh
```

Review and improve:

## 3.1 Environment handling

The existing `.env` parser uses grep-based extraction.

Replace fragile parsing where appropriate.

Requirements:

- Follow Docker Compose environment semantics.
- Preserve custom variables.
- Preserve user configuration.
- Do not overwrite `.env` wholesale on every deployment.
- Validate required variables.
- Never print secrets.

## 3.2 Password generation

Review:

```bash
openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
```

Avoid SIGPIPE failures under:

```bash
set -euo pipefail
```

Use a predictable, cryptographically secure generator with exact output length.

## 3.3 Idempotency

Repeated deployment must:

- Preserve database contents.
- Preserve Redis data where configured.
- Preserve user-defined environment variables.
- Avoid duplicate Docker networks.
- Avoid duplicate volumes.
- Avoid unnecessary container recreation.
- Maintain existing service configuration.

## 3.4 Healthchecks

Requirements:

- Wait for actual healthy status.
- Use bounded timeouts.
- Fail deployment when critical services remain unhealthy.
- Display useful diagnostics.
- Never report success when a critical service is unavailable.

## 3.5 Resource validation

Check:

- Available RAM.
- Disk space.
- Docker availability.
- Docker Compose availability.
- Required network.
- Existing containers.
- Volume ownership and permissions.

Deliverable:
A robust deployment script that is safe to execute repeatedly.

---

# PHASE 4 — Backup and Restore

Scope:

```text
backup.sh
services/mariadb-redis/backup.sh
```

First consolidate duplicated logic where safe.

## 4.1 MariaDB backup

Use:

```bash
mariadb-dump --single-transaction
```

Investigate:

- All databases.
- Users and grants.
- Routines.
- Events.
- Triggers.
- Character sets.
- Large database handling.
- Consistent backups.

The backup must be compressed and validated.

For example:

```bash
gzip -t backup.sql.gz
```

Do not rotate old backups until the new backup has been successfully created and validated.

## 4.2 Redis backup

The current fixed sleep after `BGSAVE` is unreliable.

Implement a real completion check:

- Trigger BGSAVE.
- Wait for background save completion.
- Check `LASTSAVE`.
- Verify the resulting snapshot.
- Validate file size.
- Report errors.

Do not copy an old `dump.rdb` as if it were a new backup.

## 4.3 Backup retention

Implement configurable retention:

- Daily backups.
- Retention period.
- Optional remote storage.
- Safe cleanup.

## 4.4 Restore

Create a documented restore procedure.

Requirements:

- Explicit confirmation before destructive restore.
- Backup validation before restoration.
- Existing database protection.
- Clear rollback procedure.
- MariaDB and Redis restore instructions.
- Post-restore health verification.

## 4.5 Backup testing

Test:

- Empty database.
- Multiple databases.
- Large database.
- Missing credentials.
- Missing dump utility.
- Interrupted backup.
- Corrupted backup.
- Redis save failure.
- Restore into a clean environment.

Deliverables:

- Backup implementation.
- Restore implementation or documented restore tooling.
- Backup/restore documentation.

---

# PHASE 5 — install.sh Refactoring

Scope:

```text
install.sh
```

The installer is a critical component.

Do not rewrite it from scratch.

Preserve existing features:

- Bare installation.
- Standard installation.
- System checks.
- SSH configuration.
- UFW.
- Fail2ban.
- Swap.
- Caddy.
- Cloudflare Origin Certificate.
- OpenShip CLI.
- systemd.
- Diagnostics.

Refactor into maintainable modules.

Proposed structure:

```text
lib/
├── common.sh
├── system.sh
├── security.sh
├── docker.sh
├── openship.sh
└── proxy.sh
```

Responsibilities:

### common.sh

- Logging.
- Error handling.
- Prompts.
- Confirmation.
- Color output.
- Cleanup traps.

### system.sh

- OS detection.
- RAM and disk checks.
- Hostname.
- Timezone.
- Swap.

### security.sh

- SSH.
- UFW.
- Fail2ban.
- Unattended upgrades.

### docker.sh

- Docker Engine.
- Docker Compose.
- Docker network.
- Docker validation.

### openship.sh

- OpenShip CLI.
- Configuration.
- systemd.
- Update and diagnostics.

### proxy.sh

- Caddy.
- SSL.
- Cloudflare.
- Reverse proxy.

## 5.1 Installer correctness

Investigate:

- Ubuntu version validation.
- FQDN validation.
- TTY and interactive prompt behavior.
- Non-interactive execution.
- Interrupted installation.
- Partial installation recovery.
- Secret leakage.
- Error handling.
- Cleanup traps.

## 5.2 CLI options

Consider adding:

```bash
--dry-run
--non-interactive
--help
--version
```

`--non-interactive` must require all mandatory configuration values.

`--dry-run` must not perform destructive operations.

## 5.3 Backwards compatibility

Preserve existing installation behavior unless a migration is explicitly documented.

Validate both Bare and Standard modes.

---

# PHASE 6 — Diagnostics and Updates

Scope:

```text
doctor.sh
update.sh
```

Review:

- Docker status.
- Docker Compose status.
- OpenShip CLI version.
- systemd service.
- Caddy status.
- API connectivity.
- Dashboard connectivity.
- WebSocket connectivity.
- Worker connectivity.
- Docker network connectivity.
- MariaDB health.
- Redis health.
- Disk and RAM.
- Certificate expiration.

Requirements:

- Clear exit codes.
- Actionable diagnostic output.
- No secret exposure.
- No automatic destructive repairs.
- Update must preserve configuration and persistent data.
- Provide a rollback strategy.

Diagnostics must distinguish:

- Warning.
- Failure.
- Not installed.
- Not applicable.

---

# PHASE 7 — Testing and CI

Introduce automated validation.

## 7.1 Static analysis

Use:

- ShellCheck.
- Bash syntax validation.
- Docker Compose configuration validation.
- YAML validation.
- Markdown link validation where practical.

Commands:

```bash
bash -n install.sh
bash -n update.sh
bash -n doctor.sh
bash -n backup.sh
shellcheck install.sh update.sh doctor.sh backup.sh
docker compose config -q
```

Run equivalent checks for service scripts and Compose files.

## 7.2 Tests

Test at minimum:

- Fresh install.
- Upgrade.
- Repeated deployment.
- Missing dependencies.
- Invalid configuration.
- Missing Docker network.
- Database health failure.
- Redis health failure.
- Backup failure.
- Restore.
- Interrupted execution.

Use disposable test environments.

Never run destructive tests against production.

## 7.3 CI

Create a GitHub Actions workflow.

Suggested jobs:

1. Shell syntax.
2. ShellCheck.
3. YAML validation.
4. Compose validation.
5. Unit tests.
6. Integration tests where practical.

CI must not require production secrets.

---

# PHASE 8 — Documentation and Release

Update documentation only after implementation and tests are complete.

Required documentation:

```text
README.md
docs/
├── architecture.md
├── installation.md
├── configuration.md
├── worker-setup.md
├── mariadb-redis.md
├── phpmyadmin.md
├── backup-restore.md
├── troubleshooting.md
├── upgrade.md
└── security.md
```

Document:

- Control VPS architecture.
- Worker VPS architecture.
- Docker network requirements.
- Environment variables.
- Multi-project database setup.
- Redis isolation.
- phpMyAdmin access.
- Backup and restore.
- Update procedure.
- Recovery procedure.
- Common errors.

Update `.env.example` with comments and safe defaults.

Do not include real secrets.

Prepare:

- Changelog.
- Migration notes.
- Release notes.
- Version compatibility matrix.

Do not create a release or tag without approval.

---

## 5. Definition of Done

The project is considered ready only when:

- [ ] No unexplained duplicated configuration remains.
- [ ] OpenShip network compatibility is verified.
- [ ] MariaDB deployment is repeatable and safe.
- [ ] Redis configuration is documented and validated.
- [ ] phpMyAdmin is optional and correctly connected.
- [ ] Multiple service instances can coexist where supported.
- [ ] Existing data survives upgrades.
- [ ] Environment configuration survives redeployment.
- [ ] Backup files are validated.
- [ ] Restore procedure has been tested.
- [ ] Installer retains existing functionality.
- [ ] Bare and Standard modes are validated.
- [ ] Doctor provides actionable diagnostics.
- [ ] Update process is safe.
- [ ] CI checks pass.
- [ ] Documentation reflects actual implementation.
- [ ] No secrets are committed.
- [ ] Rollback procedures are documented.

## 6. Execution and approval gates

Use the following approval process:

### Gate A — Discovery

Perform Phase 0 and Phase 1.

Do not edit files.

Present:

- Architecture findings.
- Critical issues.
- Compatibility findings.
- Proposed implementation order.
- Estimated complexity.

Wait for approval.

### Gate B — Service stack

Implement Phase 2 and Phase 3.

Before implementation, show the proposed file-level changes.

Wait for approval.

### Gate C — Backup and restore

Implement Phase 4.

Wait for approval before destructive integration testing.

### Gate D — Installer

Implement Phase 5 and Phase 6.

Preserve the current installation path.

Wait for approval before replacing the entry-point script or changing installation defaults.

### Gate E — Validation

Implement Phase 7.

Run tests and report actual results.

### Gate F — Release preparation

Implement Phase 8.

Prepare release notes, but do not publish or push without approval.

## 7. Final reporting format

At the end of each phase, use:

```text
PHASE: X / 8
STATUS: COMPLETE / BLOCKED / NEEDS APPROVAL

CHANGED FILES:
- ...

IMPLEMENTED:
- ...

TESTS:
- ...

FAILED:
- ...

RISKS:
- ...

NEXT PHASE:
- ...

APPROVAL REQUIRED:
- YES / NO
```

Do not claim that a test passed unless it was actually executed.

If a test cannot be executed, state why and provide the exact command needed to run it.

## 8. First action

Start with Phase 0.

Inspect the repository and its current state.

Then perform Phase 1 to establish OpenShip compatibility.

Do not modify any files.

Return the audit, architecture map, critical findings and proposed execution plan.

Wait for explicit approval before making the first change.
