<!-- BEGIN_TF_DOCS -->
# wanted-cloud/terraform-kubernetes-test-runner

Terraform building block declaring ONE test run as a Kubernetes CronJob, suspended
unless a schedule is given.

Deliberately agnostic about WHAT the run does. A load generator, a browser suite, a
synthetic page audit and a crawler differ only in container shape — image, resources, a
memory-backed /dev/shm, somewhere to put artifacts — and share every bit of the hard
part: suspension semantics, a computed deadline so a hung run cannot wedge the schedule
under Forbid, retries off, and a guard against a run whose results go nowhere. Those
differences are inputs; the scheduling is the block.

A CronJob rather than a Job, deliberately. A Job is immutable, so any change to the
pod spec forces replacement — Terraform would destroy the completed Job and create a
new one, which means `terraform apply` on unrelated infrastructure would FIRE A LOAD
TEST. With `wait_for_completion` it would also block the apply for the run's duration
and fail an infrastructure apply on a threshold breach. A CronJob is a durable
description of how to run: applying it twice does not run it twice, and firing is
decoupled from apply.

An on-demand scenario is therefore a SUSPENDED CronJob — a stored run spec that never
fires itself — instantiated when wanted with:

    kubectl -n <namespace> create job <name>-$(date +%s) --from=cronjob/<name>

Both paths then share one spec, so a run fired by hand is provably the same run as a
scheduled one. `fire_command` is exported so callers need not reconstruct it.

The block is deliberately ignorant: it names no vendor, no product and no specific
client-IP header, because those are what make a block reusable across estates.
It creates no namespace, no ServiceAccount and no NetworkPolicy — a namespace is
created by whatever owns the estate's workloads, a ServiceAccount's identity half
lives in the identity domain, and network policy is platform-owned.

## Table of contents

- [Requirements](#requirements)
- [Providers](#providers)
- [Variables](#inputs)
- [Outputs](#outputs)
- [Resources](#resources)
- [Design notes](#design-notes)
- [Usage](#usage)
- [Contributing](#contributing)

## Requirements

The following requirements are needed by this module:

- <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) (>= 1.11)

- <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) (~> 3.0)

## Providers

The following providers are used by this module:

- <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) (3.2.1)

## Required Inputs

The following input variables are required:

### <a name="input_image"></a> [image](#input\_image)

Description: Runner image, including tag. Pin it: `latest` makes a run unreproducible and therefore unusable as a baseline.

Type: `string`

### <a name="input_name"></a> [name](#input\_name)

Description: Run name. Becomes the CronJob name and the app.kubernetes.io/instance label, and is what `kubectl create job --from=cronjob/<name>` refers to.

Type: `string`

### <a name="input_namespace"></a> [namespace](#input\_namespace)

Description: Existing namespace to run in. NOT created here — namespaces are created by whatever owns the estate's workloads, and their network policy is platform-owned.

Type: `string`

### <a name="input_run"></a> [run](#input\_run)

Description: How long the run is expected to take, and how much of it happens at once.

`expected_duration_seconds` is a NUMBER rather than a duration string because the run's  
hard deadline is computed from it. It is an EXPECTATION, not a limit: a browser suite  
has no declared duration, so give a realistic upper estimate and the deadline follows.

`concurrency` means virtual users to a load generator and is meaningless to a page  
audit, so it is optional and simply absent from the runner's environment when null.

Type:

```hcl
object({
    expected_duration_seconds = number
    concurrency               = optional(number)
  })
```

### <a name="input_service_account_name"></a> [service\_account\_name](#input\_service\_account\_name)

Description: Existing ServiceAccount to run as. NOT created here — its identity half (workload-identity federation to a cloud identity) belongs to the identity domain.

Type: `string`

### <a name="input_target"></a> [target](#input\_target)

Description: What to generate load against.

`address` is the trick that keeps the real ingress in the path while bypassing anything  
in front of it: resolve the hostname to the ingress address, and the request still  
carries the real Host and SNI, so it matches the real ingress route and terminates real  
TLS. null uses normal DNS resolution.

Type:

```hcl
object({
    host    = string
    scheme  = optional(string, "https")
    address = optional(string)
  })
```

## Optional Inputs

The following input variables are optional (have default values):

### <a name="input_args"></a> [args](#input\_args)

Description: Arguments passed to the image's entrypoint. Empty relies on the image's own default command.

Type: `list(string)`

Default: `[]`

### <a name="input_artifacts"></a> [artifacts](#input\_artifacts)

Description: Where a run leaves traces, video, HTML reports or screenshots. Without a claim the  
artifacts vanish with the pod, which makes a failed browser run uninvestigable — the one  
case where you most want them.

Irrelevant to a run that only emits metrics; leave `claim_name` null and no volume is  
created.

Type:

```hcl
object({
    claim_name = optional(string)
    mount_path = optional(string, "/artifacts")
  })
```

Default: `{}`

### <a name="input_automount_service_account_token"></a> [automount\_service\_account\_token](#input\_automount\_service\_account\_token)

Description: Mount the Kubernetes API token into the runner pod. False by default: a test runner never calls the Kubernetes API. Note the pod-level setting overrides the ServiceAccount's, so setting it on the account alone does nothing.

Type: `bool`

Default: `false`

### <a name="input_backoff_limit"></a> [backoff\_limit](#input\_backoff\_limit)

Description: Job retries. 0 by default because retrying a load test is wrong: it doubles the load applied to the target and yields a second contaminated result, and a threshold breach is a finding rather than a transient error.

Type: `number`

Default: `0`

### <a name="input_client_identity"></a> [client\_identity](#input\_client\_identity)

Description: How each concurrent worker identifies itself to the target, so a per-client rate  
limiter sees many clients rather than one. Relevant to a load run; typically left at  
the default for a browser suite, which generates too little traffic to be limited.

`header` is parameterised on purpose — a vendor-specific client-IP header would tie  
this block to one CDN. `X-Forwarded-For` is the portable default. Note that the  
reverse proxy in front of the target must trust the generator's source for the header  
to survive; otherwise every virtual user collapses into a single bucket.

mode: per\_vu | per\_iteration | fixed. `fixed` collapses them deliberately, which is  
how you test the limiter rather than the application.

Type:

```hcl
object({
    header = optional(string, "X-Forwarded-For")
    mode   = optional(string, "per_vu")
  })
```

Default: `{}`

### <a name="input_deadline_factor"></a> [deadline\_factor](#input\_deadline\_factor)

Description: Multiplier applied to run.expected\_duration\_seconds when computing the run deadline.

Type: `number`

Default: `1.5`

### <a name="input_deadline_grace_seconds"></a> [deadline\_grace\_seconds](#input\_deadline\_grace\_seconds)

Description: Added to the computed deadline to cover image pull, credential acquisition and the generator's own summary phase. The deadline exists because with concurrency\_policy Forbid a hung run blocks EVERY later run indefinitely.

Type: `number`

Default: `120`

### <a name="input_env"></a> [env](#input\_env)

Description: Extra plain environment variables for the generator.

Type: `map(string)`

Default: `{}`

### <a name="input_history_limits"></a> [history\_limits](#input\_history\_limits)

Description: n/a

Type:

```hcl
object({
    successful = optional(number, 3)
    failed     = optional(number, 3)
  })
```

Default: `{}`

### <a name="input_image_pull_policy"></a> [image\_pull\_policy](#input\_image\_pull\_policy)

Description: n/a

Type: `string`

Default: `"IfNotPresent"`

### <a name="input_kind"></a> [kind](#input\_kind)

Description: What kind of test this run performs: load, e2e, vitals, crawl or custom. The block does not behave differently per kind — it is a label, and the honest way to keep the block ignorant of the runner it schedules.

Type: `string`

Default: `"load"`

### <a name="input_metadata"></a> [metadata](#input\_metadata)

Description: Metadata definitions for the module, this is optional construct allowing override of the module defaults defintions of validation expressions, error messages, resource timeouts and default tags.

Type:

```hcl
object({
    resource_timeouts = optional(
      map(
        object({
          create = optional(string, "30m")
          read   = optional(string, "5m")
          update = optional(string, "30m")
          delete = optional(string, "30m")
        })
      ), {}
    )
    tags                     = optional(map(string), {})
    validator_error_messages = optional(map(string), {})
    validator_expressions    = optional(map(string), {})
  })
```

Default: `{}`

### <a name="input_metrics"></a> [metrics](#input\_metrics)

Description: Where run metrics go. Prefer otlp\_endpoint when the collector is already reachable — it avoids opening a second path for a second protocol.

Type:

```hcl
object({
    prometheus_remote_write_url = optional(string)
    otlp_endpoint               = optional(string)
    trend_stats                 = optional(string, "p(95),p(99),avg,max")
  })
```

Default: `{}`

### <a name="input_options_json"></a> [options\_json](#input\_options\_json)

Description: Run options as JSON, mounted from a ConfigMap. null means the image's baked-in options are used and no ConfigMap is created.

Type: `string`

Default: `null`

### <a name="input_options_mount_path"></a> [options\_mount\_path](#input\_options\_mount\_path)

Description: n/a

Type: `string`

Default: `"/etc/load-generator"`

### <a name="input_profile"></a> [profile](#input\_profile)

Description: Shape of the run: smoke, load, soak, spike or full. Advisory to the runner; also a metric label.

Type: `string`

Default: `"smoke"`

### <a name="input_resources"></a> [resources](#input\_resources)

Description: Container resources. A runner starved of CPU measures itself rather than the target, so requests should be generous — and a browser needs far more memory than an HTTP client.

Type:

```hcl
object({
    requests = optional(map(string), { cpu = "250m", memory = "256Mi" })
    limits   = optional(map(string), { cpu = "2", memory = "1Gi" })
  })
```

Default: `{}`

### <a name="input_schedule"></a> [schedule](#input\_schedule)

Description: Cron expression, or null for on-demand only. null ships the CronJob SUSPENDED with a  
never-occurring expression, so it is a stored run spec that fires only when a person
(or a later automation) instantiates it. Setting this is how a cadence is enabled, and  
it should be set only once run-to-run variance shows a schedule can detect anything.

Type: `string`

Default: `null`

### <a name="input_secret_env"></a> [secret\_env](#input\_secret\_env)

Description: Environment variables sourced from existing Secrets, keyed by env var name. Referenced, never rendered into the manifest or into state.

Type:

```hcl
map(object({
    secret = string
    key    = string
  }))
```

Default: `{}`

### <a name="input_shared_memory_size"></a> [shared\_memory\_size](#input\_shared\_memory\_size)

Description: Size of a memory-backed /dev/shm, e.g. "1Gi". Chromium-based browsers crash on the container default of 64Mi, and the failure does not mention shared memory. null creates no volume, which is correct for a plain HTTP runner.

Type: `string`

Default: `null`

### <a name="input_starting_deadline_seconds"></a> [starting\_deadline\_seconds](#input\_starting\_deadline\_seconds)

Description: n/a

Type: `number`

Default: `60`

### <a name="input_tags"></a> [tags](#input\_tags)

Description: Labels stamped on every sample (cluster, env, git\_sha, ...). Required in practice: metric backends often apply their external labels only on egress, so a pushed sample carries only what the run itself sets.

Type: `map(string)`

Default: `{}`

## Outputs

The following outputs are exported:

### <a name="output_active_deadline_seconds"></a> [active\_deadline\_seconds](#output\_active\_deadline\_seconds)

Description: Computed hard bound on a single run.

### <a name="output_fire_command"></a> [fire\_command](#output\_fire\_command)

Description: Ready-to-run command that instantiates a one-off run from this CronJob. Exported so callers need not reconstruct it, and so the on-demand path is discoverable from a plan rather than from documentation.

### <a name="output_name"></a> [name](#output\_name)

Description: The CronJob's name.

### <a name="output_namespace"></a> [namespace](#output\_namespace)

Description: Namespace the runner runs in.

### <a name="output_suspended"></a> [suspended](#output\_suspended)

Description: True when this run is on-demand only, i.e. it will never fire itself.

## Resources

The following resources are used by this module:

- [kubernetes_config_map_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) (resource)
- [kubernetes_cron_job_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) (resource)

## Design notes

### Why a CronJob and not a Job

A Job is immutable, so any change to the pod spec forces replacement. Under Terraform that
means `terraform apply` would destroy the completed Job and create a new one — an apply on
unrelated infrastructure would **fire a load test**. With `wait_for_completion` it would
also block the apply for the run's duration and fail an infrastructure apply on a
threshold breach. A CronJob is a durable description of *how* to run: applying it twice
does not run it twice, and firing is decoupled from apply.

### On-demand is a suspended CronJob

With `schedule = null` the CronJob is created suspended, with a cron expression
(`0 0 31 2 *`) that parses but can never occur. Both belt and braces: the impossible date
states the intent in the manifest, and `suspend` means un-suspending by hand does not
silently arm a schedule nobody chose. Instantiate a run from the stored spec with the
command exported as `fire_command`.

The consequence worth knowing: on-demand and scheduled runs share ONE spec, so a run fired
by hand is provably the same run as a scheduled one.

### Retries are off by default

`backoff_limit` defaults to `0`. Retrying a load test doubles the load applied to the
target and yields a second, contaminated result for the same run — and a threshold breach
is a finding, not a transient error to paper over.

### The run deadline is mandatory, and computed

`active_deadline_seconds` is derived from `load.duration_seconds` rather than left to the
caller, because with `concurrency_policy = "Forbid"` a single hung run blocks **every**
later run indefinitely.

### What this block does not own

No namespace, no ServiceAccount, no NetworkPolicy. A namespace is created by whatever owns
the estate's workloads; a ServiceAccount's identity half belongs to the identity domain;
and network policy is platform-owned. They are inputs.

### Timeouts

The kubernetes provider exposes no `timeouts` block on `kubernetes_cron_job_v1`, so the
framework's per-resource timeout convention does not apply. `active_deadline_seconds` is
the bound that matters here.

## Usage

> For more detailed examples navigate to the `examples` folder of this repository.

```hcl
module "load_generator" {
  source  = "wanted-cloud/load-generator/kubernetes"
  version = "x.y.z"
}
```

### Basic usage example

```hcl
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
```
## Contributing

_Contributions follow the common [Contributions guidelines](https://github.com/wanted-cloud/.github/blob/main/docs/CONTRIBUTING.md)._
---
<sup><sub>_2026 &copy; All rights reserved - WANTED.solutions s.r.o._</sub></sup>
<!-- END_TF_DOCS -->
