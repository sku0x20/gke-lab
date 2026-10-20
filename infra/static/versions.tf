terraform {
  required_version = "~> 1.13"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
    # ephemeral random_password: generated values never reach state
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # hardcoded: a backend block can't read env vars like $GOOGLE_PROJECT
  backend "gcs" {
    bucket = "lab-gke-2610-tfstate"
    prefix = "infra/static"
  }
}
