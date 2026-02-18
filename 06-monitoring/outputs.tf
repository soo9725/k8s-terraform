output "grafana_url" {
  description = "Grafana Dashboard URL"
  value       = "https://grafana.${var.domain_name}"
}

output "grafana_admin_password" {
  description = "Grafana 초기 비밀번호"
  value       = "test123"
}