# 06-monitoring/helm.tf

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
          retention = "1d" # 데이터 1일만 보관
          resources = {
            requests = { memory = "256Mi", cpu = "200m" }
            limits   = { memory = "1Gi", cpu = "500m" }
          }
          nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
        }
      }

      # [Alertmanager] Slack Webhook 연동 (기존 설정 유지)
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
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
                  api_url = var.slack_webhook_url
                  channel = "#k8s" 
                  send_resolved = true
                  title = "{{ .GroupLabels.alertname }}"
                  text = "{{ range .Alerts }}*Alert:* {{ .Annotations.summary }}\n*Description:* {{ .Annotations.description }}\n{{ end }}"
                }
              ]
            }
          ]
        }
      }

      # [Grafana] Loki 연결 및 Ingress 설정
      grafana = {
        adminPassword = "test123" 
        
        # [핵심 추가] Grafana에게 Loki의 위치를 알려주는 설정 (자동 연결)
        additionalDataSources = [
          {
            name = "Loki"
            type = "loki"
            url  = "http://loki.monitoring.svc.cluster.local:3100"
            access = "proxy"
            jsonData = {
              maxLines = 1000
            }
          }
        ]

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
          enabled = false
        }
        resources = {
          requests = { memory = "128Mi", cpu = "100m" }
          limits   = { memory = "512Mi", cpu = "500m" }
        }
        nodeSelector = { "karpenter.sh/capacity-type" = "on-demand" }
      }
      promtail = {
        enabled = true
        # Promtail Readiness Probe 이슈 해결 (Timeout 증가)
        readinessProbe = {
          initialDelaySeconds = 15
          timeoutSeconds      = 5
        }
      }
    })
  ]
  depends_on = [helm_release.prometheus_stack]
}

# -------------------------------------------------------------
# 3. BotKube (Slack ChatOps) - [v1.14.0 안정 버전]
# -------------------------------------------------------------
resource "helm_release" "botkube" {
  name             = "botkube"
  repository       = "https://charts.botkube.io"
  chart            = "botkube"
  namespace        = "botkube"
  create_namespace = true
  version          = "1.14.0" # [핵심] K8s 1.30 호환성 및 Panic 버그 수정 버전

  values = [
    yamlencode({
      # [설정] 클러스터 이름 지정 (not-configured 해결)
      settings = {
        clusterName = "terraform-eks"
      }

      communications = {
        "default-group" = {
          socketSlack = {
            enabled = true
            appToken = var.slack_app_token
            botToken = var.slack_bot_token
            channels = {
              "default" = {
                name = var.slack_channel_id
                bindings = {
                  sources = ["k8s-events"]
                  executors = ["kubectl-exec"]
                }
              }
            }
          }
        }
      }

      sources = {
        "k8s-events" = {
          "botkube/kubernetes" = {
            enabled = true
            context = {
              rbac = {
                group = {
                  type = "Static"
                  static = {
                    values = ["botkube-plugins-default"]
                  }
                }
              }
            }
            config = {
              namespaces = {
                include = [".*"]
              }
              # [수정] 이벤트 필터링 레벨 추가 (Info 레벨까지 감시)
              event = {
                types = ["create", "update", "delete", "error"]
                levels = ["info", "error", "warning"]
              }
              resources = [
                {
                  type = "v1/pods"
                  namespaces = { include = [".*"] }
                  events = ["create", "delete", "error"]
                },
                {
                  type = "v1/nodes" # [복구] 1.14에선 이제 뻗지 않습니다!
                  namespaces = { include = [".*"] }
                  events = ["create", "delete"]
                }
              ]
            }
          }
        }
      }

      executors = {
        "kubectl-exec" = {
          "botkube/kubectl" = {
            enabled = true
            context = {
              rbac = {
                group = {
                  type = "Static"
                  static = {
                    values = ["botkube-plugins-default"]
                  }
                }
              }
            }
            config = {
              defaultNamespace = "default"
              namespaces = {
                include = [".*"]
              }
              commands = {
                verbs = ["get", "describe", "logs", "top", "cluster-info", "diff"]
                resources = ["deployments", "pods", "nodes", "services", "ingresses", "hpa", "scaledobjects"]
              }
            }
          }
        }
      }

      rbac = {
        create = true
        groups = {
          "botkube-plugins-default" = {
            create = true
            rules = [
              {
                apiGroups = ["*"]
                resources = ["*"]
                verbs     = ["get", "watch", "list", "describe", "logs", "top"]
              }
            ]
          }
        }
      }
    })
  ]
}