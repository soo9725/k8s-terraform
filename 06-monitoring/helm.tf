# -------------------------------------------------------------
# 1. Prometheus & Grafana (kube-prometheus-stack)
# -------------------------------------------------------------
resource "helm_release" "prometheus_stack" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "56.6.2" # Stable Version

  values = [
    yamlencode({
      # [리소스 최적화] 노드 메모리 8GB 고려
      prometheus = {
        prometheusSpec = {
          retention = "1d" # 데이터 1일만 보관 (매일 삭제하므로)
          resources = {
            requests = { memory = "256Mi", cpu = "200m" }
            limits   = { memory = "1Gi", cpu = "500m" }
          }
          # 모니터링은 중요하므로 On-Demand 노드 강제
          nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
        }
      }

      # [Alertmanager] Slack Webhook 연동
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
           # Alertmanager도 리소스 줄임
           resources = {
             requests = { memory = "64Mi", cpu = "100m" }
           }
        }
        config = {
          global = { resolve_timeout = "5m" }
          route = {
            group_by = ["alertname", "job"]
            group_wait = "30s"
            group_interval = "5m"
            repeat_interval = "12h"
            receiver = "slack-notifications"
            routes = [
              {
                matchers = ["severity =~ \"critical|warning\""]
                receiver = "slack-notifications"
              }
            ]
          }
          receivers = [
            {
              name = "slack-notifications"
              slack_configs = [
                {
                  api_url = var.slack_webhook_url # 변수에서 주입
                  channel = "#k8s"  # (채널명은 Webhook 설정 따름)
                  send_resolved = true
                  title = "{{ .GroupLabels.alertname }}"
                  text = "{{ range .Alerts }}*Alert:* {{ .Annotations.summary }}\n*Description:* {{ .Annotations.description }}\n{{ end }}"
                }
              ]
            }
          ]
        }
      }

      # [Grafana] Ingress(ALB) 설정 및 비밀번호 고정
      grafana = {
        adminPassword = "test123" # 매일 초기화되므로 비밀번호 고정 (편의성)
        
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          hosts            = ["grafana.${var.domain_name}"]
          path             = "/"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"      = "ip"
            "alb.ingress.kubernetes.io/group.name"       = "terraform-k8s"
            "alb.ingress.kubernetes.io/certificate-arn"  = var.acm_certificate_arn
            "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}, {\"HTTP\":80}]"
            "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
            "alb.ingress.kubernetes.io/success-codes"    = "200-399"
          }
        }
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
    })
  ]
}

# -------------------------------------------------------------
# 2. Loki & Promtail (로그 수집)
# -------------------------------------------------------------
resource "helm_release" "loki_stack" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = "monitoring"
  version    = "2.10.2"

  values = [
    yamlencode({
      loki = {
        persistence = {
          enabled = false # 매일 삭제하므로 EBS 안 쓰고 임시 저장소 사용 (비용 절감)
        }
        resources = {
          requests = { memory = "128Mi", cpu = "100m" }
          limits   = { memory = "512Mi", cpu = "500m" }
        }
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      promtail = {
        enabled = true # 로그 수집기
        #nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
    })
  ]
  depends_on = [helm_release.prometheus_stack]
}

# -------------------------------------------------------------
# 3. BotKube (Slack ChatOps)
# -------------------------------------------------------------
resource "helm_release" "botkube" {
  name             = "botkube"
  repository       = "https://charts.botkube.io"
  chart            = "botkube"
  namespace        = "botkube"
  create_namespace = true
  version          = "1.10.0"

  values = [
    yamlencode({
      communications = {
        "default-group" = {
          socketSlack = {
            enabled = true
            channels = {
              "default" = {
                name = var.slack_channel_id # 변수에서 주입 (ID 필수)
                bindings = {
                  sources = ["k8s-events"]
                  executors = ["kubectl-exec"]
                }
              }
            }
            appToken = var.slack_app_token # 변수에서 주입
            botToken = var.slack_bot_token
          }
        }
      }

      # 봇이 감지할 이벤트 설정 (파드 생성/삭제/에러 등)
      sources = {
        "k8s-events" = {
          botkube = {
            kubernetes = {
              namespaces = { include = [".*"] } # 모든 네임스페이스 감시
              resources = [
                {
                  type = "v1/pods"
                  namespaces = { include = [".*"] }
                  events = ["create", "delete", "error"]
                },
                {
                  type = "v1/nodes"
                  events = ["create", "delete"] # Karpenter 노드 증감 알림
                }
              ]
            }
          }
        }
      }

      # 챗옵스 실행 권한 (kubectl)
      executors = {
        "kubectl-exec" = {
          botkube = {
            kubectl = {
              enabled = true
              namespaces = { include = [".*"] }
              commands = {
                verbs = ["get", "describe", "logs", "top"] # 위험한 delete는 제외 (안전 제일)
                resources = ["deployments", "pods", "nodes", "services", "ingresses"]
              }
            }
          }
        }
      }
    })
  ]
}