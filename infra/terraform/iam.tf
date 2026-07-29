# ---------------------------------------------------------------------------
# IAM: least-privilege access for the application, plus the roles required to
# authenticate against and operate an EKS cluster.
# ---------------------------------------------------------------------------

# --- 1. What the application is allowed to do ------------------------------
data "aws_iam_policy_document" "app_permissions" {
  # DynamoDB: only the verbs the code actually calls, only on this table.
  # No DeleteItem, no UpdateItem, no wildcard on the table ARN.
  statement {
    sid = "UserTableAccess"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:DescribeTable", # used by the readiness probe
    ]
    resources = [
      aws_dynamodb_table.users.arn,
      "${aws_dynamodb_table.users.arn}/index/*",
    ]
  }

  # S3 objects: scoped to the avatar prefix, so a compromised pod cannot read
  # or overwrite anything else that may live in the bucket later on.
  statement {
    sid = "AvatarObjectAccess"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject", # required by the compensating rollback
    ]
    resources = ["${aws_s3_bucket.avatars.arn}/${var.avatar_prefix}/*"]
  }

  # Bucket-level access is narrowed with a condition so ListBucket cannot be
  # used to enumerate keys outside the avatar prefix.
  statement {
    sid       = "AvatarBucketListing"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.avatars.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.avatar_prefix}/*", "${var.avatar_prefix}/"]
    }
  }
}

resource "aws_iam_policy" "app" {
  name        = "${var.name_prefix}-app"
  description = "Least-privilege access to the users table and the avatar prefix."
  policy      = data.aws_iam_policy_document.app_permissions.json
}

# --- 2. Who is allowed to assume the application role ----------------------
# The OIDC provider is what lets EKS exchange a projected ServiceAccount token
# for AWS credentials — no node role sharing, no static keys in the cluster.
resource "aws_iam_openid_connect_provider" "eks" {
  count = var.enable_irsa && var.create_oidc_provider ? 1 : 0

  url             = var.eks_oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"] # AWS root CA

  tags = { Name = "${var.name_prefix}-eks-oidc" }
}

data "aws_iam_policy_document" "app_assume_role" {
  dynamic "statement" {
    # Real EKS: federated trust bound to one namespace + one ServiceAccount.
    for_each = var.enable_irsa ? [1] : []
    content {
      sid     = "IRSATrust"
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type = "Federated"
        identifiers = [
          var.create_oidc_provider
          ? aws_iam_openid_connect_provider.eks[0].arn
          : "arn:${local.partition}:iam::${local.account_id}:oidc-provider/${local.oidc_host}"
        ]
      }

      # Both conditions matter: `sub` pins the exact ServiceAccount, `aud`
      # stops a token minted for another audience from being replayed here.
      condition {
        test     = "StringEquals"
        variable = "${local.oidc_host}:sub"
        values   = [local.irsa_subject]
      }

      condition {
        test     = "StringEquals"
        variable = "${local.oidc_host}:aud"
        values   = ["sts.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    # LocalStack path: EKS/OIDC do not exist there, so the role is still created
    # (policies, ARN, outputs are all identical) with an account-root trust.
    # Nothing outside the account can assume it.
    for_each = var.enable_irsa ? [] : [1]
    content {
      sid     = "LocalDevelopmentTrust"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]

      principals {
        type        = "AWS"
        identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
      }
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name_prefix}-app"
  description        = "Assumed by the ${var.kubernetes_service_account} ServiceAccount."
  assume_role_policy = data.aws_iam_policy_document.app_assume_role.json

  # Defence in depth: even if a broader policy is attached by mistake, the
  # effective permissions can never exceed this boundary.
  max_session_duration = 3600

  tags = { Name = "${var.name_prefix}-app" }
}

resource "aws_iam_role_policy_attachment" "app" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app.arn
}

# --- 3. Roles required to operate an EKS cluster ---------------------------
# Not created by default: LocalStack CE does not implement EKS, and the brief
# explicitly says not to spin up a real cluster. Enable them with
# `-var enable_eks_platform_roles=true` against a real account.
data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  count = var.enable_eks_platform_roles ? 1 : 0

  name               = "${var.name_prefix}-eks-cluster"
  description        = "Control-plane role assumed by the EKS service itself."
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  count = var.enable_eks_platform_roles ? 1 : 0

  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  count = var.enable_eks_platform_roles ? 1 : 0

  name               = "${var.name_prefix}-eks-node"
  description        = "Instance role for the managed node group."
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  # The three managed policies a worker node genuinely needs: join the cluster,
  # run the VPC CNI, and pull images from ECR. Nothing more.
  for_each = var.enable_eks_platform_roles ? toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])

  role       = aws_iam_role.eks_node[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# --- 4. Keyless deployments from GitHub Actions ----------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.enable_github_oidc ? aws_iam_openid_connect_provider.github[0].arn : ""]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restricted to this repository's main branch and tags: a fork or a PR from
    # an untrusted contributor cannot mint deployment credentials.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:ref:refs/tags/*",
        "repo:${var.github_repository}:environment:production",
      ]
    }
  }
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "DescribeClusterForKubeconfig"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "github_deploy" {
  count = var.enable_github_oidc ? 1 : 0

  name               = "${var.name_prefix}-github-deploy"
  description        = "Assumed by GitHub Actions to run helm upgrade against EKS."
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json
}

resource "aws_iam_role_policy" "github_deploy" {
  count = var.enable_github_oidc ? 1 : 0

  name   = "${var.name_prefix}-github-deploy"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy.json
}
