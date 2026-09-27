# Authenticated load. The generator mints its own token with a client-credentials grant, so
# the secret is REFERENCED from an existing Secret and never rendered into the manifest or
# into Terraform state.
#
# Client identity is X-Forwarded-For rather than a CDN's own client-IP header: a per-client
# rate limiter must see many clients or the run measures the limiter instead of the service.
# The reverse proxy in front of the target must trust this generator's source, or every
# virtual user collapses into one bucket.
module "load_generator" {
  source = "../../"

  name                 = "api-authenticated"
  namespace            = "example-testing"
  service_account_name = "example-testing"
  image                = "registry.example.com/http-load-runner:2026.09.1"

  target = {
    host = "api.example.test"
    # Resolve the hostname to the ingress address: the request still carries the real Host
    # and SNI, so it matches the real ingress route and terminates real TLS, while skipping
    # anything sitting in front of that ingress.
    address = "10.0.12.34"
  }
  load = { vus = 20, duration_seconds = 300 }

  client_identity = { header = "X-Forwarded-For", mode = "per_vu" }

  env = {
    OIDC_ISSUER    = "https://login.example.com/tenant/v2.0"
    OIDC_CLIENT_ID = "00000000-0000-0000-0000-000000000000"
    OIDC_SCOPE     = "api://example/.default"
  }

  secret_env = {
    OIDC_CLIENT_SECRET = { secret = "example-testing-oidc", key = "client-secret" }
  }

  metrics = { otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318" }
  tags    = { cluster = "example-001", env = "test" }
}
