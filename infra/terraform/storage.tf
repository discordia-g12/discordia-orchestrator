# Imágenes de usuario (avatares e íconos de servidor) en S3.
#   avatars/       → Auth-User-Service
#   server-icons/  → Server-Roles-Core-Service
# Cada servicio escribe con su propio usuario IAM, que solo puede tocar su prefijo: no depende del rol ni
# de la metadata de la EC2 donde corre, así que puede moverse a cualquier nodo (o fuera de AWS) sin cambios.
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

# Un usuario por servicio, con permiso de escribir y borrar solo en su prefijo.
# Las access keys NO se crean acá (quedarían en texto plano en el estado): ver output media_access_key_commands.
resource "aws_iam_user" "media" {
  for_each = local.media_writers

  name = "discordia-${each.key}-media"
}

resource "aws_iam_user_policy" "media" {
  for_each = local.media_writers

  name = "write-${each.value}"
  user = aws_iam_user.media[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.media.arn}/${each.value}/*"
    }]
  })
}
