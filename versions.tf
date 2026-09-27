/*
 * This file is used to define the versions of the providers that are used in the module.
 */

terraform {
  required_version = ">= 1.11"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # Pinned to the 3.x line deliberately. ">= 2.35.0" floated ACROSS a major version —
      # a fresh init silently resolved 3.2.1 — which turns any later init into an unplanned
      # upgrade window for a provider whose major releases carry breaking schema changes.
      version = "~> 3.0"
    }
  }
}
