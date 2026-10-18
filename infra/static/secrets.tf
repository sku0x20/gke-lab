# Valkey's ACL file (users and passwords), mounted into the pod by the Secret Manager add-on.
# tofu owns the secret, not the value: versions are added by k8s/valkey/add-acl-secret.sh
resource "google_secret_manager_secret" "valkey_acl" {
  secret_id = "valkey-acl"

  # Google picks the locations; billed as one location
  replication {
    auto {}
  }
}
