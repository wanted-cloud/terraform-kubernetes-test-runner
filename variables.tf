variable "name" {
  description = "Run name. Becomes the CronJob name and the app.kubernetes.io/instance label, and is what `kubectl create job --from=cronjob/<name>` refers to."
  type        = string
}

variable "namespace" {
  description = "Existing namespace to run in. NOT created here — namespaces are created by whatever owns the estate's workloads, and their network policy is platform-owned."
  type        = string
}

variable "service_account_name" {
  description = "Existing ServiceAccount to run as. NOT created here — its identity half (workload-identity federation to a cloud identity) belongs to the identity domain."
  type        = string
}

variable "image" {
  description = "Runner image, including tag. Pin it: `latest` makes a run unreproducible and therefore unusable as a baseline."
  type        = string
}

variable "image_pull_policy" {
  type    = string
  default = "IfNotPresent"
}

variable "args" {
  description = "Arguments passed to the image's entrypoint. Empty relies on the image's own default command."
  type        = list(string)
  default     = []
}

variable "schedule" {
  description = <<-EOT
    Cron expression, or null for on-demand only. null ships the CronJob SUSPENDED with a
    never-occurring expression, so it is a stored run spec that fires only when a person
    (or a later automation) instantiates it. Setting this is how a cadence is enabled, and
    it should be set only once run-to-run variance shows a schedule can detect anything.
  EOT
  type        = string
  default     = null
}

variable "kind" {
  description = "What kind of test this run performs: load, e2e, vitals, crawl or custom. The block does not behave differently per kind — it is a label, and the honest way to keep the block ignorant of the runner it schedules."
  type        = string
  default     = "load"

  validation {
    condition     = can(regex(local.metadata.validator_expressions["kind"], var.kind))
    error_message = local.metadata.validator_error_messages["kind"]
  }
}

variable "profile" {
  description = "Shape of the run: smoke, load, soak, spike or full. Advisory to the runner; also a metric label."
  type        = string
  default     = "smoke"

  validation {
    condition     = can(regex(local.metadata.validator_expressions["profile"], var.profile))
    error_message = local.metadata.validator_error_messages["profile"]
  }
}

variable "target" {
  description = <<-EOT
    What to generate load against.

    `address` is the trick that keeps the real ingress in the path while bypassing anything
    in front of it: resolve the hostname to the ingress address, and the request still
    carries the real Host and SNI, so it matches the real ingress route and terminates real
    TLS. null uses normal DNS resolution.
  EOT
  type = object({
    host    = string
    scheme  = optional(string, "https")
    address = optional(string)
  })

  validation {
    condition     = can(regex(local.metadata.validator_expressions["scheme"], var.target.scheme))
    error_message = local.metadata.validator_error_messages["scheme"]
  }
}

variable "run" {
  description = <<-EOT
    How long the run is expected to take, and how much of it happens at once.

    `expected_duration_seconds` is a NUMBER rather than a duration string because the run's
    hard deadline is computed from it. It is an EXPECTATION, not a limit: a browser suite
    has no declared duration, so give a realistic upper estimate and the deadline follows.

    `concurrency` means virtual users to a load generator and is meaningless to a page
    audit, so it is optional and simply absent from the runner's environment when null.
  EOT
  type = object({
    expected_duration_seconds = number
    concurrency               = optional(number)
  })

  validation {
    condition     = var.run.expected_duration_seconds > 0
    error_message = "run.expected_duration_seconds must be greater than zero — the run deadline is derived from it."
  }

  validation {
    condition     = var.run.concurrency == null || var.run.concurrency > 0
    error_message = "run.concurrency must be greater than zero when set."
  }
}

variable "client_identity" {
  description = <<-EOT
    How each concurrent worker identifies itself to the target, so a per-client rate
    limiter sees many clients rather than one. Relevant to a load run; typically left at
    the default for a browser suite, which generates too little traffic to be limited.

    `header` is parameterised on purpose — a vendor-specific client-IP header would tie
    this block to one CDN. `X-Forwarded-For` is the portable default. Note that the
    reverse proxy in front of the target must trust the generator's source for the header
    to survive; otherwise every virtual user collapses into a single bucket.

    mode: per_vu | per_iteration | fixed. `fixed` collapses them deliberately, which is
    how you test the limiter rather than the application.
  EOT
  type = object({
    header = optional(string, "X-Forwarded-For")
    mode   = optional(string, "per_vu")
  })
  default = {}

  validation {
    condition     = can(regex(local.metadata.validator_expressions["mode"], var.client_identity.mode))
    error_message = local.metadata.validator_error_messages["mode"]
  }
}

variable "metrics" {
  description = "Where run metrics go. Prefer otlp_endpoint when the collector is already reachable — it avoids opening a second path for a second protocol."
  type = object({
    prometheus_remote_write_url = optional(string)
    otlp_endpoint               = optional(string)
    trend_stats                 = optional(string, "p(95),p(99),avg,max")
  })
  default = {}

  validation {
    # Explicit null-and-empty checks rather than coalesce(): Terraform's coalesce treats ""
    # as absent AND RAISES when every argument is absent, so it throws an error instead of
    # returning false. Empty string is the realistic failure here — an unset pipeline
    # variable interpolates to "", not to null — and it would otherwise plan silently.
    condition = (
      (var.metrics.prometheus_remote_write_url != null && var.metrics.prometheus_remote_write_url != "") ||
      (var.metrics.otlp_endpoint != null && var.metrics.otlp_endpoint != "")
    )
    error_message = "Set metrics.prometheus_remote_write_url or metrics.otlp_endpoint — a run whose results go nowhere cannot be read, and its absence is silent."
  }
}

variable "tags" {
  description = "Labels stamped on every sample (cluster, env, git_sha, ...). Required in practice: metric backends often apply their external labels only on egress, so a pushed sample carries only what the run itself sets."
  type        = map(string)
  default     = {}
}

variable "env" {
  description = "Extra plain environment variables for the generator."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Environment variables sourced from existing Secrets, keyed by env var name. Referenced, never rendered into the manifest or into state."
  type = map(object({
    secret = string
    key    = string
  }))
  default = {}
}

variable "options_json" {
  description = "Run options as JSON, mounted from a ConfigMap. null means the image's baked-in options are used and no ConfigMap is created."
  type        = string
  default     = null
}

variable "options_mount_path" {
  type    = string
  default = "/etc/load-generator"
}

variable "resources" {
  description = "Container resources. A runner starved of CPU measures itself rather than the target, so requests should be generous — and a browser needs far more memory than an HTTP client."
  type = object({
    requests = optional(map(string), { cpu = "250m", memory = "256Mi" })
    limits   = optional(map(string), { cpu = "2", memory = "1Gi" })
  })
  default = {}
}

variable "artifacts" {
  description = <<-EOT
    Where a run leaves traces, video, HTML reports or screenshots. Without a claim the
    artifacts vanish with the pod, which makes a failed browser run uninvestigable — the one
    case where you most want them.

    Irrelevant to a run that only emits metrics; leave `claim_name` null and no volume is
    created.
  EOT
  type = object({
    claim_name = optional(string)
    mount_path = optional(string, "/artifacts")
  })
  default = {}
}

variable "shared_memory_size" {
  description = "Size of a memory-backed /dev/shm, e.g. \"1Gi\". Chromium-based browsers crash on the container default of 64Mi, and the failure does not mention shared memory. null creates no volume, which is correct for a plain HTTP runner."
  type        = string
  default     = null
}

variable "backoff_limit" {
  description = "Job retries. 0 by default because retrying a load test is wrong: it doubles the load applied to the target and yields a second contaminated result, and a threshold breach is a finding rather than a transient error."
  type        = number
  default     = 0
}

variable "starting_deadline_seconds" {
  type    = number
  default = 60
}

variable "history_limits" {
  type = object({
    successful = optional(number, 3)
    failed     = optional(number, 3)
  })
  default = {}
}

variable "deadline_factor" {
  description = "Multiplier applied to run.expected_duration_seconds when computing the run deadline."
  type        = number
  default     = 1.5
}

variable "deadline_grace_seconds" {
  description = "Added to the computed deadline to cover image pull, credential acquisition and the generator's own summary phase. The deadline exists because with concurrency_policy Forbid a hung run blocks EVERY later run indefinitely."
  type        = number
  default     = 120
}
