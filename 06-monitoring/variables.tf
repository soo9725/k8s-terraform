variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project Name"
  type        = string
  default     = "terraform-k8s"
}

variable "domain_name" {
  description = "Grafana 접속용 도메인 (예: soo9725.site)"
  type        = string
  default     = "soo9725.site"
}

variable "acm_certificate_arn" {
  description = "HTTPS 인증서 ARN (Layer 2, 4와 동일)"
  type        = string
  default     = "arn:aws:acm:ap-northeast-1:894168368940:certificate/f9e48831-30dd-4343-849a-b964ed021783"
}

# --- [Slack Sensitive Data] ---
# terraform apply 할 때 -var로 넣거나 terraform.tfvars 파일로 관리 권장

variable "slack_bot_token" {
  description = "Slack App Bot User OAuth Token (xoxb-...)"
  type        = string
  sensitive   = true # 로그에 출력되지 않음
}

variable "slack_channel_id" {
  description = "BotKube가 메시지를 보낼 채널 ID"
  type        = string
}

variable "slack_webhook_url" {
  description = "Alertmanager가 알람을 보낼 Webhook URL"
  type        = string
  sensitive   = true
}

variable "slack_app_token" { # [신규 추가] Socket Mode용
  description = "App-Level Token (xapp-...)"
  type        = string
  sensitive   = true
}