# 카카오 REST OAuth가 Android 앱으로 돌아오기 위한 HTTPS App Link 호스트.
# 별도 도메인을 구매하지 않고 CloudFront 기본 도메인과 인증서를 사용한다.

data "aws_caller_identity" "callback" {}

locals {
  kakao_callback_bucket_name = "dib-kakao-callback-${data.aws_caller_identity.callback.account_id}"
  android_debug_sha256       = "5C:60:0C:81:77:D9:92:92:5D:FE:63:21:E9:C2:F1:BD:33:87:1A:CE:E7:90:D7:38:37:32:76:1A:C7:6D:61:C4"
}

resource "aws_s3_bucket" "kakao_callback" {
  bucket        = local.kakao_callback_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "kakao_callback" {
  bucket = aws_s3_bucket.kakao_callback.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "assetlinks" {
  bucket        = aws_s3_bucket.kakao_callback.id
  key           = ".well-known/assetlinks.json"
  content_type  = "application/json"
  cache_control = "no-cache"
  content = jsonencode([
    {
      relation = ["delegate_permission/common.handle_all_urls"]
      target = {
        namespace                = "android_app"
        package_name             = "com.ssafy.dib"
        sha256_cert_fingerprints = [local.android_debug_sha256]
      }
    }
  ])
}

resource "aws_s3_object" "kakao_callback_fallback" {
  bucket        = aws_s3_bucket.kakao_callback.id
  key           = "oauth/kakao/callback"
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
  content       = <<-HTML
    <!doctype html>
    <html lang="ko">
      <head><meta charset="utf-8"><title>DIB 카카오 로그인</title></head>
      <body><p>DIB 앱에서 카카오 로그인을 다시 시도해 주세요.</p></body>
    </html>
  HTML
}

resource "aws_cloudfront_origin_access_control" "kakao_callback" {
  name                              = "dib-kakao-callback"
  description                       = "OAC for the private DIB Kakao callback bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_distribution" "kakao_callback" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "DIB Kakao OAuth Android App Link"
  price_class     = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.kakao_callback.bucket_regional_domain_name
    origin_id                = "kakao-callback-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.kakao_callback.id
  }

  default_cache_behavior {
    target_origin_id       = "kakao-callback-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_disabled.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "kakao_callback_bucket" {
  statement {
    sid     = "AllowCloudFrontRead"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.kakao_callback.arn}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.kakao_callback.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "kakao_callback" {
  bucket = aws_s3_bucket.kakao_callback.id
  policy = data.aws_iam_policy_document.kakao_callback_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.kakao_callback]
}
