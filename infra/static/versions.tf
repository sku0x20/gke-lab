terraform {
  required_version = "~> 1.13"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
  }

  # hardcoded: a backend block can't read env vars like $GOOGLE_PROJECT
  backend "gcs" {
    bucket = "lab-gke-2610-tfstate"
    prefix = "infra/static"
  }
}
