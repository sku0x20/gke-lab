data "aws_caller_identity" "current" {}

/*
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  value = data.aws_caller_identity.current.arn
}

output "caller_user" {
  value = data.aws_caller_identity.current.user_id
}
*/

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  current_iamRole = data.aws_iam_session_context.current.issuer_arn
}

/*
output "source_role_arn" {
  value = data.aws_iam_session_context.current.issuer_arn
}

output "source_role_name" {
  value = data.aws_iam_session_context.current.issuer_name
}
*/