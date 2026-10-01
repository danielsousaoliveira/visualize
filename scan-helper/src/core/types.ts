/* ---------- Docker Compose ---------- */

/**
 * A container healthcheck as authored in compose (`services.<name>.healthcheck`),
 * shaped after the Docker Engine Healthcheck object. `test` is either a shell
 * string (compose `test: "curl ..."`) or an array. The compose parser reduces an
 * array to bare argv, but an array reaching the runtime MAY still carry its
 * original `CMD` / `CMD-SHELL` / `NONE` prefix — app-catalog services and API
 * callers pass compose's own form through verbatim — so the runtime honors both
 * (see `toDockerHealthcheck`) and no producer has to normalize first. Durations
 * stay as compose strings ("30s", "1m30s") — the runtime converts them to
 * nanoseconds at container-create time. `disable` mirrors compose
 * `healthcheck.disable: true` (turns off an image's baked-in check → Docker
 * `Test: ["NONE"]`).
 */
export type ComposeHealthcheck = {
  test?: string | string[];
  interval?: string;
  timeout?: string;
  retries?: number;
  startPeriod?: string;
  disable?: boolean;
};

/**
 * Extended compose fields that don't warrant their own first-class columns.
 * Stored as ONE JSONB blob (`service.advanced`) and nested inside the drift
 * `ComposeServiceSpec` so 3-way reconciliation covers it like any other
 * compose-owned field. Grows per phase (labels, entrypoint, extra_hosts, dns,
 * cap_add, …); because it's JSONB, every addition is a pure TS shape-widening —
 * no migration. Runtimes that can't honor a key (e.g. the cloud runtime for
 * host-level options) warn-and-drop rather than fail. Lives in @repo/core so
 * both @repo/db (storage) and @repo/adapters (runtime) can share one definition.
 */
/**
 * Openship's own DEPLOY-TIME readiness gate — the sibling of, and NOT the same
 * thing as, `ComposeHealthcheck` above.
 *
 *   ComposeHealthcheck  = the Docker HEALTHCHECK directive. An arbitrary command
 *                         ("pg_isready", "curl -f /health") that the DAEMON runs
 *                         on an interval, forever, to mark a container
 *                         healthy/unhealthy. Custom conditions, continuous.
 *   OpenshipReadiness   = "did this thing actually come up?", asked ONCE by the
 *                         deploy pipeline between "started" and "ready". A port
 *                         that accepts a connection (optionally an HTTP path that
 *                         answers < 500), a static site whose doc-root has a
 *                         servable index, and/or a container that didn't fall into
 *                         a restart loop. It is the only one that can hold up — or
 *                         veto — a deploy.
 *
 * EVERYTHING HERE IS OFF BY DEFAULT, and that is the point. Omit the block and a
 * deploy does no post-start waiting whatsoever: activate → route → ready. The
 * pipeline still runs *advisory* probes once the deploy is live (`auditPorts` →
 * `meta.portCheck`, `auditStaticOutput` → `meta.outputCheck`, both re-runnable on
 * demand), so "is it listening?" and "will it 404?" are answered without a gate
 * that can delay or fail a working deploy.
 *
 * Turn these on when you want the deploy itself to refuse to go green — e.g. a
 * release pipeline that must not advance on a broken build.
 *
 * Settable per PROJECT (the project's `readiness` column) and per compose SERVICE
 * (`service.advanced.readiness`, which overrides the project's for that service).
 */
export type OpenshipReadiness = {
  /**
   * Probe the workload after start and wait for it to answer — a port for a
   * running process, servable files for a static site. `false`/absent ⇒ no probe
   * is issued at all (the default).
   */
  enabled?: boolean;
  /**
   * Require an HTTP GET to this path to answer below 500. Omit to accept a bare
   * TCP connection, which also passes for non-HTTP services. Ignored by the
   * static-file probe, which checks the doc-root instead.
   */
  path?: string;
  /** Port to probe. Defaults to the workload's own port. */
  port?: number;
  /** How long to wait for the workload to answer. Default 45. */
  timeoutSeconds?: number;
  /**
   * Watch the container for a restart loop before reporting ready. Independent of
   * `enabled` — this reads the runtime (so it also covers remote/SSH targets)
   * rather than dialing anything. `false`/absent ⇒ not watched.
   */
  stabilization?: boolean;
  /** How long to watch for a restart loop. Default 15. */
  stabilizationSeconds?: number;
  /**
   * What a failed check does.
   *   "warn" (default) — the deploy stays `ready` and carries an
   *                      action-required warning. Never destroys anything.
   *   "fail"           — the deploy fails and reverts to the previous
   *                      deployment, which keeps serving.
   */
  onFailure?: OpenshipReadinessFailureAction;
};

export type OpenshipReadinessFailureAction = "warn" | "fail";

export type ComposeAdvanced = {
  /**
   * Provenance for a Compose `image:` expression. `resolved` remains in the
   * service's ordinary `image` column for display and rollback snapshots; this
   * record keeps the authored expression so deployment can evaluate it against
   * the final project environment instead of freezing a scan-time value.
   *
   * `unresolvedVariables` describes the scan-time scope. It lets deploy safely
   * reuse a concrete value supplied by the compose-adjacent `.env` file when
   * that file is not part of the runtime environment, while still refusing a
   * genuinely unresolved expression. Internal/compose-owned.
   */
  imageTemplate?: {
    expression: string;
    unresolvedVariables: string[];
    /** Value produced by the compose-adjacent `.env` before project env is
     * overlaid. Used only to recognize an untouched legacy scan during the
     * one-time provenance migration. */
    sourceValue?: string;
  };
  /**
   * Environment keys whose stored inline value is the original Compose
   * interpolation expression. Values stay in the masked `environment` column;
   * this names-only marker lets deploy resolve them against the final env layers
   * without exposing expressions (which may contain secret defaults) elsewhere.
   * Internal/compose-owned: API clients do not author this field.
   */
  environmentTemplateKeys?: string[];
  /** Inline environment keys explicitly edited, removed, or kept during drift
   * review. Names only; template provenance still controls interpolation. */
  environmentOverrideKeys?: string[];
  /**
   * Build-argument keys whose stored value is the original expression from a
   * raw Compose file. Unlike `buildArgs` received from the CLI (already expanded
   * by `docker compose config`) or a direct API call, these keys are expanded
   * once against the deployment's final build environment.
   *
   * Names only: values remain in `buildArgs`. Compose-owned and safe to
   * round-trip through service/deployment responses.
   */
  buildArgTemplateKeys?: string[];
  healthcheck?: ComposeHealthcheck;
  /** False opts this service out of steady-state outage monitoring and Docker
   * event acceleration. Deployment readiness remains independent. */
  monitoringEnabled?: boolean;
  /**
   * Per-service deploy-time readiness gate, overriding the project's for THIS
   * service. Absent ⇒ inherit the project's; neither ⇒ off.
   *
   * Distinct from `healthcheck` above in both what it asks and what it can do:
   * that one is a daemon-run custom command, this one is the pipeline's one-shot
   * "did it come up?" and is the only one that can fail a deploy.
   */
  readiness?: OpenshipReadiness;
  /**
   * Generated config files bind-mounted (read-only) into this service's
   * container at deploy — seeded from an app template's `files` (e.g. Kong's
   * `kong.yml`, Postgres init `.sql`). Content is resolved at install (generated
   * keys) with `{{publicUrl:…}}` left for deploy-time substitution. JSONB blob —
   * no migration.
   */
  files?: { path: string; content: string }[];
  /**
   * Inline Docker build context for a service that must be BUILT, not pulled
   * (seeded from an app template's `service.build`). At deploy the pipeline
   * materializes `dockerfile` + `files` to a temp context on the orchestrator and
   * runs `docker build` on the deploy host; the resulting image ref feeds the
   * container. `dockerfile`/`files[].content` are resolved at install (generated
   * keys). Mutually exclusive with a pulled `service.image`. JSONB blob — no
   * migration.
   */
  build?: {
    dockerfile: string;
    files?: { path: string; content: string }[];
  };
  /**
   * Per-service cpu/memory caps authored in the compose file, normalized from
   * either the short form (`mem_limit`, `cpus`) or the swarm form
   * (`deploy.resources.limits.{memory,cpus}`). These were silently dropped
   * before — an uploaded compose that asked for 4 GB still got the project-wide
   * value — so a service that declares its own limit now overrides the project
   * default at deploy time. `0`/absent = inherit the project (see
   * UNLIMITED_RESOURCES in ./resources).
   */
  resources?: { cpuCores?: number; memoryMb?: number };
  /**
   * Compose `network_mode` — the network namespace this service SHARES instead of
   * getting its own. `"none"`, `"service:<name>"` (a sibling in this stack), or
   * `"container:<id>"`. Absent = the normal case: its own endpoint on the project
   * network. `host` is refused at import, not stored — see compose-namespace.ts
   * for that decision and for the parsing rules.
   *
   * Sharing has consequences the runtime enforces, because Docker rejects the
   * combinations outright: a shared-netns container publishes no ports, joins no
   * network, and carries no DNS alias. Its provider must also be created FIRST,
   * so this doubles as a start-order dependency (`composeNamespaceDependencies`).
   */
  networkMode?: string;
  /**
   * Compose `pid` — the PID namespace to share (`"service:<name>"` /
   * `"container:<id>"`). Same resolution and ordering rules as `networkMode`, and
   * the same `host` refusal; unlike it, sharing a pid namespace costs the service
   * nothing else (it keeps its own network identity, ports, and aliases).
   */
  pidMode?: string;
  /**
   * Custom east-west DNS alias for this service, resolving ALONGSIDE the default
   * `service.name` on the project network — both names reach the container. Set
   * so another service can address this one by a stable, operator-chosen name
   * (e.g. `db` instead of `postgres-1`). Normalized with `normalizeServiceLabel`
   * before it reaches Docker; the single-app equivalent is `project.internal_alias`.
   * An alias existing is not exposure — publish stays loopback-only behind the edge.
   */
  alias?: string;
  /**
   * Compose `entrypoint` — the container's ENTRYPOINT, as argv.
   *
   * The other half of container shape, and it has to distinguish three states that
   * a plain `string[]` expresses exactly:
   *
   *   absent  ⇒ the image's own ENTRYPOINT runs (unchanged).
   *   `[]`    ⇒ CLEAR it (`Entrypoint: []`). This is the deliberate form — pairing
   *             `entrypoint: []` with a `command` is how you run a binary directly
   *             in an image whose ENTRYPOINT is a wrapper — and it used to be the
   *             most silent failure of the lot: `requestsSomething` reads an empty
   *             array as "asks for nothing", so it produced no warning either (#575).
   *   argv    ⇒ replace it (a debug shim, `wait-for-it.sh`, a privilege dropper).
   *
   * No implicit `sh -c`, matching what #332 settled for `command`: a compose string
   * is shell-WORD-SPLIT into argv (`commandToArgv`), so running a shell takes an
   * explicit `sh -c`. Unlike `command` there is no companion text column to keep in
   * step — nothing predates this field, so argv is the only representation.
   */
  entrypoint?: string[];
  /**
   * Compose `stop_signal` — the signal Docker sends to ask this container to shut
   * down (`"SIGINT"`, `"SIGQUIT"`, a bare number). Absent ⇒ Docker's default
   * `SIGTERM`. Maps to the container's top-level `StopSignal`.
   */
  stopSignal?: string;
  /**
   * Compose `stop_grace_period` — how long Docker waits after `stopSignal` before
   * it `SIGKILL`s the container, kept as a compose duration string ("30s", "1m")
   * the runtime rounds to whole seconds for the container's top-level
   * `StopTimeout`. Absent ⇒ Docker's default (10s). Matters for workloads that
   * flush or checkpoint on shutdown and need longer than the default.
   */
  stopGracePeriod?: string;
};
