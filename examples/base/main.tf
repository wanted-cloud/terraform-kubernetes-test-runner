# Minimal call: one on-demand scenario. No schedule, so the CronJob ships SUSPENDED and
# fires only when someone instantiates it from the stored spec.
module "load_generator" {
  source = "../../"

  name                 = "checkout-endpoints"
  namespace            = "example-testing"
  service_account_name = "example-testing"
  image                = "registry.example.com/http-load-runner:2026.09.1"

  target = { host = "app.example.test" }
  load   = { vus = 5, duration_seconds = 60 }

  metrics = { otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318" }
  tags    = { cluster = "example-001", env = "test" }
}

output "fire" {
  value = module.load_generator.fire_command
}
