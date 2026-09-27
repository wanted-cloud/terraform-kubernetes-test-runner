# A browser run — the case that shows why this block is not a load generator.
#
# Same scheduling, different container shape. Nothing about the CronJob semantics changes:
# what changes is that a browser needs shared memory, somewhere durable for its artifacts,
# and far more RAM than an HTTP client.
module "test_run" {
  source = "../../"

  name                 = "checkout-journey"
  namespace            = "example-testing"
  service_account_name = "example-testing"
  image                = "registry.example.com/browser-runner:2026.09.1"

  kind    = "e2e"
  profile = "full"

  # No `address` override: a browser run goes through the REAL public path, because for a
  # website the CDN and cache behaviour is part of what is being measured. A load run does
  # the opposite and resolves straight to the ingress, since volume is what makes a CDN a
  # problem.
  target = { host = "app.example.test" }

  # No concurrency: virtual users are meaningless to a browser suite. The duration is an
  # estimate, and the run deadline is computed from it.
  run = { expected_duration_seconds = 600 }

  # Chromium-based browsers crash on the container default of 64Mi, and the failure message
  # never mentions shared memory.
  shared_memory_size = "1Gi"

  # Traces, video and reports outlive the pod only if something durable holds them —
  # which is exactly what a failed run needs.
  artifacts = { claim_name = "example-testing-artifacts" }

  resources = {
    requests = { cpu = "1", memory = "2Gi" }
    limits   = { cpu = "2", memory = "4Gi" }
  }

  metrics = { otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318" }
  tags    = { cluster = "example-001", env = "test" }
}
