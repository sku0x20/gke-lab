terraform {
  backend "s3" {
    bucket = "tf-state-ff857864"
    key    = "k8s-eks"
    region = "ap-south-1"
  }
}