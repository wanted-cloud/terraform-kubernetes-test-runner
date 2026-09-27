# A scheduled soak. Setting `schedule` un-suspends the CronJob, so it fires itself.
#
# Enable a cadence only once run-to-run variance shows one can detect anything: on a shared
# environment the number partly reflects what the neighbours were doing, and an alert
# threshold loose enough to avoid false alarms may catch nothing at all.
module "load_generator" {
  source = "../../"

  name                 = "checkout-soak"
  namespace            = "example-testing"
  service_account_name = "example-testing"
  image                = "registry.example.com/http-load-runner:2026.09.1"

  schedule = "0 3 * * 0" # Sundays at 03:00
  profile  = "soak"

  target = { host = "app.example.test" }
  load   = { vus = 50, duration_seconds = 1800 }

  # 1800s * 1.5 + 120 = a 2820s hard bound. The deadline is not optional: with
  # concurrency_policy Forbid a hung run blocks every later run indefinitely.
  deadline_factor = 1.5

  metrics = { otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318" }
  tags    = { cluster = "example-001", env = "test" }
}
