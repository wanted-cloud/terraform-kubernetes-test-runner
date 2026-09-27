/*
 * # wanted-cloud/terraform-kubernetes-test-runner
 *
 * Terraform building block declaring ONE test run as a Kubernetes CronJob, suspended
 * unless a schedule is given.
 *
 * Deliberately agnostic about WHAT the run does. A load generator, a browser suite, a
 * synthetic page audit and a crawler differ only in container shape — image, resources, a
 * memory-backed /dev/shm, somewhere to put artifacts — and share every bit of the hard
 * part: suspension semantics, a computed deadline so a hung run cannot wedge the schedule
 * under Forbid, retries off, and a guard against a run whose results go nowhere. Those
 * differences are inputs; the scheduling is the block.
 *
 * A CronJob rather than a Job, deliberately. A Job is immutable, so any change to the
 * pod spec forces replacement — Terraform would destroy the completed Job and create a
 * new one, which means `terraform apply` on unrelated infrastructure would FIRE A LOAD
 * TEST. With `wait_for_completion` it would also block the apply for the run's duration
 * and fail an infrastructure apply on a threshold breach. A CronJob is a durable
 * description of how to run: applying it twice does not run it twice, and firing is
 * decoupled from apply.
 *
 * An on-demand scenario is therefore a SUSPENDED CronJob — a stored run spec that never
 * fires itself — instantiated when wanted with:
 *
 *     kubectl -n <namespace> create job <name>-$(date +%s) --from=cronjob/<name>
 *
 * Both paths then share one spec, so a run fired by hand is provably the same run as a
 * scheduled one. `fire_command` is exported so callers need not reconstruct it.
 *
 * The block is deliberately ignorant: it names no vendor, no product and no specific
 * client-IP header, because those are what make a block reusable across estates.
 * It creates no namespace, no ServiceAccount and no NetworkPolicy — a namespace is
 * created by whatever owns the estate's workloads, a ServiceAccount's identity half
 * lives in the identity domain, and network policy is platform-owned.
 */

resource "kubernetes_cron_job_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    schedule                      = coalesce(var.schedule, local.never)
    suspend                       = var.schedule == null
    concurrency_policy            = "Forbid" # never overlap: two generators would measure each other
    starting_deadline_seconds     = var.starting_deadline_seconds
    successful_jobs_history_limit = var.history_limits.successful
    failed_jobs_history_limit     = var.history_limits.failed

    job_template {
      metadata {
        labels = local.labels
      }

      spec {
        # 0 by default: retrying a load test is wrong. A retry doubles the load applied to
        # the target and produces a second, contaminated result for the same run — and a
        # threshold breach is a finding, not a transient error to paper over.
        backoff_limit           = var.backoff_limit
        active_deadline_seconds = local.active_deadline_seconds

        template {
          metadata {
            labels = local.labels
          }

          spec {
            service_account_name = var.service_account_name
            restart_policy       = "Never"

            # The POD-level setting wins over the ServiceAccount's, and the provider defaults
            # it to true — so turning it off on the account alone silently mounts the API
            # token anyway. A test runner never calls the Kubernetes API, and it is the least
            # trusted workload in the cluster, so it gets no token.
            automount_service_account_token = var.automount_service_account_token

            container {
              name              = "runner"
              image             = var.image
              image_pull_policy = var.image_pull_policy

              args = var.args

              dynamic "env" {
                for_each = local.run_env
                content {
                  name  = env.key
                  value = env.value
                }
              }

              # Secret-borne values (an OIDC client secret, an API token) are referenced,
              # never rendered into the manifest or into Terraform state as plaintext.
              dynamic "env" {
                for_each = var.secret_env
                content {
                  name = env.key
                  value_from {
                    secret_key_ref {
                      name = env.value.secret
                      key  = env.value.key
                    }
                  }
                }
              }

              dynamic "volume_mount" {
                for_each = var.options_json == null ? [] : [1]
                content {
                  name       = "options"
                  mount_path = var.options_mount_path
                  read_only  = true
                }
              }

              # Chromium-based browsers crash on the container default of 64Mi shared memory,
              # with an error that looks nothing like "out of /dev/shm". Irrelevant to an
              # HTTP generator, mandatory for a browser suite.
              dynamic "volume_mount" {
                for_each = var.shared_memory_size == null ? [] : [1]
                content {
                  name       = "dshm"
                  mount_path = "/dev/shm"
                }
              }

              dynamic "volume_mount" {
                for_each = var.artifacts.claim_name == null ? [] : [1]
                content {
                  name       = "artifacts"
                  mount_path = var.artifacts.mount_path
                }
              }

              resources {
                requests = var.resources.requests
                limits   = var.resources.limits
              }
            }

            dynamic "volume" {
              for_each = var.options_json == null ? [] : [1]
              content {
                name = "options"
                config_map {
                  name = kubernetes_config_map_v1.this[0].metadata[0].name
                }
              }
            }

            dynamic "volume" {
              for_each = var.shared_memory_size == null ? [] : [1]
              content {
                name = "dshm"
                empty_dir {
                  medium     = "Memory"
                  size_limit = var.shared_memory_size
                }
              }
            }

            # Traces, video and reports outlive the pod only if something durable holds
            # them. A run whose artifacts vanish with the pod cannot be investigated.
            dynamic "volume" {
              for_each = var.artifacts.claim_name == null ? [] : [1]
              content {
                name = "artifacts"
                persistent_volume_claim {
                  claim_name = var.artifacts.claim_name
                }
              }
            }
          }
        }
      }
    }
  }

  # NB: the kubernetes provider exposes no `timeouts` block on this resource, so the
  # framework's per-resource timeout convention does not apply here. The run's own hard
  # bound is `active_deadline_seconds` on the job template above, which is the timeout that
  # actually matters: it is what stops a hung run from wedging the schedule forever under
  # concurrency_policy Forbid.
}
