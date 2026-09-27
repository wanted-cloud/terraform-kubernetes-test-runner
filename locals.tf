locals {
  definitions = {
    tags = {
      ManagedBy = "Terraform"
      Component = "test-runner"
    }

    validator_expressions = {
      kind    = "^(load|e2e|vitals|crawl|custom)$"
      profile = "^(smoke|load|soak|spike|full)$"
      mode    = "^(per_vu|per_iteration|fixed)$"
      scheme  = "^(http|https)$"
    }
    validator_error_messages = {
      kind    = "kind must be one of load, e2e, vitals, crawl or custom."
      profile = "profile must be one of smoke, load, soak, spike or full."
      mode    = "client_identity.mode must be per_vu, per_iteration or fixed."
      scheme  = "target.scheme must be http or https."
    }
  }

  # A CronJob's schedule field is REQUIRED, so an on-demand-only generator still needs a
  # value. 31 February parses as a valid cron expression and can never occur, which states
  # the intent in the manifest itself. `suspend` below is belt and braces: it means that
  # un-suspending by hand does not silently arm a schedule nobody chose.
  never = "0 0 31 2 *"

  # Bound every run. With concurrency_policy Forbid a hung run blocks EVERY later run
  # indefinitely, so the deadline is derived from the declared duration rather than left to
  # a caller to remember. Grace covers image pull, credential acquisition, browser startup and the runner's own reporting phase.
  active_deadline_seconds = ceil(var.run.expected_duration_seconds * var.deadline_factor) + var.deadline_grace_seconds

  labels = merge(local.metadata.tags, {
    "app.kubernetes.io/name"      = "test-runner"
    "app.kubernetes.io/instance"  = var.name
    "app.kubernetes.io/component" = var.kind
  })

  # Run identity handed to the harness. Kept as plain env so the block stays ignorant of
  # which harness implements it.
  run_env = merge(
    {
      RUN_NAME         = var.name
      RUN_PROFILE      = var.profile
      TARGET_URL       = "${var.target.scheme}://${var.target.host}"
      TARGET_HOST      = var.target.host
      VUS              = tostring(var.load.vus)
      DURATION_SECONDS = tostring(var.load.duration_seconds)
      CLIENT_ID_HEADER = var.client_identity.header
      CLIENT_ID_MODE   = var.client_identity.mode
      RUN_TAGS         = join(",", [for k, v in var.tags : "${k}=${v}"])
    },
    # Resolve the ingress by IP while still sending the real Host and SNI, so the run
    # traverses the real ingress route without depending on public DNS.
    var.run.concurrency == null ? {} : { CONCURRENCY = tostring(var.run.concurrency) },
    var.artifacts.claim_name == null ? {} : { ARTIFACTS_DIR = var.artifacts.mount_path },
    var.target.address == null ? {} : { TARGET_ADDRESS = var.target.address },
    var.metrics.prometheus_remote_write_url == null ? {} : {
      # Tool-NEUTRAL names. The block declares WHERE results go; each runner image's
      # entrypoint maps these onto whatever its own tool expects. Emitting one tool's
      # variable names here would quietly make this a block for that tool — a browser
      # runner has no notion of a trend stat.
      METRICS_PROMETHEUS_RW_URL = var.metrics.prometheus_remote_write_url
      METRICS_TREND_STATS       = var.metrics.trend_stats
    },
    var.metrics.otlp_endpoint == null ? {} : {
      OTEL_EXPORTER_OTLP_ENDPOINT = var.metrics.otlp_endpoint
    },
    var.env,
  )
}
