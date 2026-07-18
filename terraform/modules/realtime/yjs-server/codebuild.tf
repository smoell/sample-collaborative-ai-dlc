# ---------------------------------------------------------------------------
# yjs-server image build via AWS CodeBuild (replaces the local docker-build
# module). Same rationale as the agents module: no local Docker/QEMU on the
# operator machine. Builds amd64 natively in AWS and pushes to ECR.
# ---------------------------------------------------------------------------

data "archive_file" "yjs_src" {
  type        = "zip"
  source_dir  = local.yjs_source_path
  output_path = "${path.module}/.build/yjs-src-${local.yjs_image_tag}.zip"
  excludes    = ["**/node_modules/**", "**/.git/**", "**/.build/**", "**/*.zip"]
}

resource "aws_s3_object" "yjs_src" {
  bucket = var.artifacts_bucket_name
  key    = "codebuild-sources/yjs-${local.yjs_image_tag}.zip"
  source = data.archive_file.yjs_src.output_path
  etag   = data.archive_file.yjs_src.output_md5
}

resource "aws_iam_role" "yjs_codebuild" {
  name = "${var.project_name}-yjs-codebuild-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.${local.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "yjs_codebuild" {
  name = "yjs-codebuild-permissions"
  role = aws_iam_role.yjs_codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:${local.partition}:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-yjs-server-${var.environment}*"
      },
      { Sid = "EcrAuth", Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
          "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.yjs_server.arn
      },
      {
        Sid      = "SourceRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.artifacts_bucket_arn}/codebuild-sources/*"
      }
    ]
  })
}

resource "aws_codebuild_project" "yjs" {
  name         = "${var.project_name}-yjs-server-${var.environment}"
  description  = "Builds the yjs-server container image and pushes it to ECR."
  service_role = aws_iam_role.yjs_codebuild.arn

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "ECR_REPO_URL"
      value = aws_ecr_repository.yjs_server.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = local.yjs_image_tag
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = data.aws_region.current.id
    }
  }

  source {
    type      = "S3"
    location  = "${var.artifacts_bucket_name}/${aws_s3_object.yjs_src.key}"
    buildspec = <<-EOT
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region "$AWS_DEFAULT_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com"
        build:
          commands:
            - docker build --platform linux/amd64 -t "$ECR_REPO_URL:$IMAGE_TAG" -f Dockerfile .
        post_build:
          commands:
            - docker push "$ECR_REPO_URL:$IMAGE_TAG"
    EOT
  }
}

resource "null_resource" "yjs_build" {
  triggers = {
    source_hash = local.yjs_files_sha
    project     = aws_codebuild_project.yjs.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION="${data.aws_region.current.id}"
      PROJECT="${aws_codebuild_project.yjs.name}"
      echo "Starting CodeBuild $PROJECT ..."
      BUILD_ID=$(aws codebuild start-build --project-name "$PROJECT" --region "$REGION" --query 'build.id' --output text)
      while true; do
        STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$REGION" --query 'builds[0].buildStatus' --output text)
        echo "  status: $STATUS"
        case "$STATUS" in
          SUCCEEDED) break ;;
          FAILED|FAULT|STOPPED|TIMED_OUT) echo "yjs build failed: $STATUS"; exit 1 ;;
          *) sleep 10 ;;
        esac
      done
    EOT
  }

  depends_on = [aws_s3_object.yjs_src, aws_codebuild_project.yjs]
}

locals {
  yjs_image_uri = "${aws_ecr_repository.yjs_server.repository_url}:${local.yjs_image_tag}"
}
