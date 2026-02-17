resource "kubectl_manifest" "kafka_cluster" {
  yaml_body = <<YAML
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
spec:
  kafka:
    version: 3.8.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
    storage:
      type: ephemeral # [중요] EBS 사용 안 함
  zookeeper:
    replicas: 3
    storage:
      type: ephemeral # [중요] EBS 사용 안 함
  entityOperator:
    topicOperator: {}
    userOperator: {}
YAML

  depends_on = [helm_release.strimzi_operator]
}