output "name" {
  description = "The CronJob's name."
  value       = kubernetes_cron_job_v1.this.metadata[0].name
}

output "namespace" {
  description = "Namespace the runner runs in."
  value       = var.namespace
}

output "suspended" {
  description = "True when this run is on-demand only, i.e. it will never fire itself."
  value       = var.schedule == null
}

output "fire_command" {
  description = "Ready-to-run command that instantiates a one-off run from this CronJob. Exported so callers need not reconstruct it, and so the on-demand path is discoverable from a plan rather than from documentation."
  value       = "kubectl -n ${var.namespace} create job ${var.name}-$(date +%s) --from=cronjob/${kubernetes_cron_job_v1.this.metadata[0].name}"
}

output "active_deadline_seconds" {
  description = "Computed hard bound on a single run."
  value       = local.active_deadline_seconds
}
