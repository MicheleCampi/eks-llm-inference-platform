provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "eks-llm-inference-platform"
      ManagedBy = "terraform"
      Owner     = "michele"
    }
  }
}
