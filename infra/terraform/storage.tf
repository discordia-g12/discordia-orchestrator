# Medios de usuario en S3.
#   avatars/       → Auth-User-Service (avatares)
#   server-icons/  → Server-Roles-Core-Service (íconos y banners de servidor)
#   attachments/   → Chat-Engine-Service (adjuntos de canales y DMs)
# Cada servicio escribe con su propio usuario IAM, que solo puede tocar su prefijo: no depende del rol ni
# de la metadata de la EC2 donde corre, así que puede moverse a cualquier nodo (o fuera de AWS) sin cambios.
# avatars/ y server-icons/ se leen sin firma, pero solo desde las páginas de Discordia (Referer). attachments/
# y el resto del bucket son privados: los adjuntos se ven con URLs firmadas que entrega Chat-Engine.

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
      Sid       = "ReadImagesFromDiscordia"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = [for prefix in local.media_public_prefixes : "${aws_s3_bucket.media.arn}/${prefix}/*"]
      # Solo si el pedido viene de una página de Discordia: el link suelto (sin Referer) o embebido en otro
      # sitio da 403. Los servicios leen y escriben con su usuario IAM, que no pasa por esta condición.
      Condition = {
        StringLike = { "aws:Referer" = var.media_allowed_referers }
      }
    }]
  })

  # AWS rechaza la policy pública si el bloqueo todavía está activo
  depends_on = [aws_s3_bucket_public_access_block.media]
}

# Un usuario por servicio, con permiso de escribir y borrar solo en su prefijo. En los prefijos privados
# también puede leer: una URL firmada solo funciona si quien la firma tiene s3:GetObject.
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
      Action   = contains(local.media_public_prefixes, each.value) ? ["s3:PutObject", "s3:DeleteObject"] : ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
      Resource = "${aws_s3_bucket.media.arn}/${each.value}/*"
    }]
  })
}
