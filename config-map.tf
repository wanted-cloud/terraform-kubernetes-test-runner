/*
 * The run's run options, mounted into the generator. A child of the CronJob: it has
 * no meaning without it, and it is created only when options are actually supplied —
 * runs whose options are baked into the image need no ConfigMap at all.
 */

resource "kubernetes_config_map_v1" "this" {
  count = var.options_json == null ? 0 : 1

  metadata {
    name      = "${var.name}-options"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "options.json" = var.options_json
  }
}
