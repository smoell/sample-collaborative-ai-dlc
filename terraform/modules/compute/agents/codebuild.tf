# ---------------------------------------------------------------------------
# Agent image build via AWS CodeBuild (replaces the local docker-build module).
#
# Why: building the large agent image locally on Apple Silicon is fragile
# (QEMU segfaults, Podman VM disk pressure, "no space left on device"). CodeBuild
# has native Docker (privileged, no emulation) and builds in AWS, so nothing but
# the AWS CLI is needed on the operator's machine.
#
# Flow: archive lambda/ -> upload to S3 (source) -> CodeBuild runs docker build
# + push to ECR (tag = agents_image_tag) -> null_resource triggers start-build
# on any source-hash change. The ECS task definition references
# "<ecr_url>:<agents_image_tag>".
# ---------------------------------------------------------------------------

# 1. Package the build context (the whole lambda/ tree the Dockerfile COPYs from).
data "archive_file" "agents_src" {
  type        = "zip"
  source_dir  = local.agents_source_path
  output_path = "${path.module}/.build/agents-src-${local.agents_image_tag}.zip"
  excludes    = ["**/node_modules/**", "**/.git/**", "**/.build/**", "**/*.zip"]
}

# 2. Upload the source zip to the artifacts bucket (passed into this module).
resource "aws_s3_object" "agents_src" {
  bucket = var.artifacts_bucket_name
  key    = "codebuild-sources/agents-${local.agents_image_tag}.zip"
  source = data.archive_file.agents_src.output_path
  etag   = data.archive_file.agents_src.output_md5
}

# 3. IAM role for CodeBuild: ECR push, S3 read (source), CloudWatch logs.
resource "aws_iam_role" "agents_codebuild" {
  name = "${var.project_name}-agents-codebuild-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.${local.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "agents_codebuild" {
  name = "agents-codebuild-permissions"
  role = aws_iam_role.agents_codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"
        ]
        Resource = "arn:${local.partition}:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-agents-${var.environment}*"
      },
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
          "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.agents.arn
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

# 4. CodeBuild project — native amd64 Docker, privileged for docker build.
resource "aws_codebuild_project" "agents" {
  name         = "${var.project_name}-agents-${var.environment}"
  description  = "Builds the AI-DLC agent container image and pushes it to ECR."
  service_role = aws_iam_role.agents_codebuild.arn

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for docker build

    environment_variable {
      name  = "ECR_REPO_URL"
      value = aws_ecr_repository.agents.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = local.agents_image_tag
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
    location  = "${var.artifacts_bucket_name}/${aws_s3_object.agents_src.key}"
    buildspec = <<-EOT
      version: 0.2
      phases:
        pre_build:
          commands:
            - echo Logging in to Amazon ECR...
            - aws ecr get-login-password --region "$AWS_DEFAULT_REGION" | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com"
        build:
          commands:
            - echo Building agent image "$ECR_REPO_URL:$IMAGE_TAG"...
            - docker build --platform linux/amd64 --build-arg IMAGE_TAG="$IMAGE_TAG" -t "$ECR_REPO_URL:$IMAGE_TAG" -f agents-ecs/Dockerfile .
        post_build:
          commands:
            - echo Pushing image to ECR...
            - docker push "$ECR_REPO_URL:$IMAGE_TAG"
            - echo Done.
    EOT
  }

  tags = var.tags
}

# 5. Trigger a build whenever the source hash changes. Uses the AWS CLI only —
# no local Docker. --wait blocks until the build finishes so the image exists
# before the ECS service is updated.
resource "null_resource" "agents_build" {
  triggers = {
    source_hash = local.agents_files_sha
    project     = aws_codebuild_project.agents.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION="${data.aws_region.current.id}"
      PROJECT="${aws_codebuild_project.agents.name}"
      echo "Starting CodeBuild $PROJECT ..."
      BUILD_ID=$(aws codebuild start-build --project-name "$PROJECT" --region "$REGION" --query 'build.id' --output text)
      echo "Build: $BUILD_ID"
      while true; do
        STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$REGION" --query 'builds[0].buildStatus' --output text)
        echo "  status: $STATUS"
        case "$STATUS" in
          SUCCEEDED) echo "Build succeeded."; break ;;
          FAILED|FAULT|STOPPED|TIMED_OUT) echo "Build failed: $STATUS"; exit 1 ;;
          *) sleep 10 ;;
        esac
      done
    EOT
  }

  # The CodeBuild service role's inline policy (logs:CreateLogStream, ECR push,
  # S3 source read) must be attached BEFORE the build starts — otherwise the
  # very first build fails in the QUEUED phase with ACCESS_DENIED on
  # logs:CreateLogStream (freshly-created policy not yet in effect). Depend on
  # the policy explicitly so the first apply is ordered correctly.
  depends_on = [aws_s3_object.agents_src, aws_codebuild_project.agents, aws_iam_role_policy.agents_codebuild]
}
