# Imágenes de usuario (avatares e íconos de servidor) en S3.
#   avatars/       → Auth-User-Service
#   server-icons/  → Server-Roles-Core-Service
# Los dos servicios corren en el nodo edge y escriben con el rol de la instancia (sin access keys).
# La lectura es pública solo en esos dos prefijos: el resto del bucket queda privado.

resource "aws_s3_bucket" "media" {
  bucket = var.media_bucket_name
}

# Sin ACLs: todo lo controla la bucket policy
resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Se permite una policy pública (la de abajo); las ACLs públicas siguen bloqueadas
resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "media_public_read" {
  bucket = aws_s3_bucket.media.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadImages"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = [for prefix in local.media_prefixes : "${aws_s3_bucket.media.arn}/${prefix}/*"]
    }]
  })

  # AWS rechaza la policy pública si el bloqueo todavía está activo
  depends_on = [aws_s3_bucket_public_access_block.media]
}

# El rol del nodo edge puede escribir y borrar solo en los prefijos de imágenes
resource "aws_iam_role_policy" "edge_media" {
  name = "discordia-edge-media"
  role = module.edge.role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = [for prefix in local.media_prefixes : "${aws_s3_bucket.media.arn}/${prefix}/*"]
    }]
  })
}
