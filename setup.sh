#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="druid"
NAMESPACE="druid"

# Helper functions
log_header() {
    echo
    echo -e "${BLUE}==========${NC} $1 ${BLUE}==========${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    commands=("docker" "kind" "kubectl" "helm")
    for cmd in "${commands[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is not installed. Please install it first."
            exit 1
        fi
    done

    # Check if Docker is running
    if ! docker info &> /dev/null; then
        log_error "Docker is not running. Please start Docker first."
        exit 1
    fi

    log_success "All prerequisites are installed and running!"
}

create_kind_cluster() {
    log_info "Creating kind cluster: $CLUSTER_NAME"

    if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
        log_info "Cluster $CLUSTER_NAME already exists. Continuing..."

        # set the context to the kind cluster
        kubectl config use-context kind-druid

        return 0
    fi

    # Create temporary data directory
    mkdir -p /tmp/druid-data

    # Create cluster
    kind create cluster --name $CLUSTER_NAME --config kind-config.yaml

    # Wait for cluster to be ready
    kubectl wait --for=condition=Ready nodes --all --timeout=300s

    # Create namespace used for installing Druid later
    kubectl apply -f manifests/namespace.yaml

    log_success "Kind cluster created successfully!"
}

install_druid_operator() {
    log_info "Installing Druid Operator..."

    # Check if Druid Operator is already installed
    if helm list -n druid-operator | grep -q "druid-operator"; then
        log_info "Druid Operator is already installed. Continuing..."
        return 0
    fi

    # Add Helm repositories
    helm repo add datainfra https://charts.datainfra.io
    helm repo update

    # Install Druid Operator
    helm install druid-operator datainfra/druid-operator \
        --namespace druid-operator \
        --create-namespace \
        --set image.tag=v1.3.0 \
        --wait --timeout=300s

    # Verify installation
    kubectl wait --for=condition=available deployment/druid-operator -n druid-operator --timeout=300s

    log_success "Druid Operator installed successfully!"
}

install_minio_operator() {
    log_info "Installing MinIO Operator..."

    # Check if MinIO Operator is already installed
    if kubectl get crd tenants.minio.min.io &> /dev/null; then
        log_info "MinIO Operator is already installed. Continuing..."
        return 0
    fi

    # Install MinIO Operator
    kubectl apply -k "github.com/minio/operator"

    # Wait for operator to be ready
    kubectl wait --for=condition=available deployment/minio-operator -n minio-operator --timeout=300s

    log_success "MinIO Operator installed successfully!"
}

deploy_minio() {
    log_info "Deploying MinIO Tenant..."

    kubectl apply -n $NAMESPACE -f manifests/minio.yaml

    # Wait for MinIO tenant to be ready
    log_info "Waiting for MinIO tenant to be ready..."
    kubectl wait --for=jsonpath='{status.currentState}'=Initialized tenant/minio -n $NAMESPACE --timeout=300s

    # Wait for bucket creation job to complete
    kubectl wait --for=condition=complete job/minio-bucket-creator -n $NAMESPACE --timeout=300s

    log_success "MinIO tenant deployed successfully!"
}

deploy_zookeeper() {
    log_info "Deploying ZooKeeper..."

    kubectl apply -n $NAMESPACE -f manifests/zookeeper.yaml

    log_success "ZooKeeper deployed successfully!"
}

deploy_postgresql() {
    log_info "Deploying PostgreSQL for Druid metadata store..."

    kubectl apply -n $NAMESPACE -f manifests/postgresql.yaml

    # Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=available deployment/postgresql -n $NAMESPACE --timeout=300s

    log_success "PostgreSQL deployed successfully!"
}

deploy_druid_cluster() {
    log_info "Deploying Druid cluster..."

    # Wait for dependencies to be ready
    log_info "Waiting for dependencies to be ready..."

    # Apply Druid cluster
    kubectl apply -n $NAMESPACE -f manifests/druid-cluster.yaml
}

wait_for_druid_cluster() {
    log_info "Waiting for Druid cluster to be ready (this may take several minutes)..."
    kubectl wait --for=jsonpath='{status.druidNodeStatus.druidNodeConditionType}'=DruidClusterReady druid/druid-cluster -n $NAMESPACE --timeout=360s
    log_success "Druid cluster created"
}

install_prometheus() {
    log_info "Installing Prometheus..."

    # Check if Prometheus is already installed
    if helm list -n monitoring | grep -q "prometheus"; then
        log_info "Prometheus is already installed. Continuing..."
        return 0
    fi

    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Add Prometheus Community Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update

    # Install Prometheus with basic configuration
    helm install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --values helm/prometheus/values.yaml \
        --set grafana.enabled=true \
        --set grafana.adminPassword=admin \
        --wait --timeout=300s

    # now that Prometheus is installed, we can deploy the Druid metrics service and service monitor
    kubectl apply -n $NAMESPACE -f manifests/druid-metrics-service.yaml
    kubectl apply -n $NAMESPACE -f manifests/druid-service-monitor.yml
}

wait_for_prometheus() {
    log_info "Waiting for Prometheus to be ready..."
    kubectl wait --for=condition=available deployment/prometheus-kube-prometheus-operator -n monitoring --timeout=300s
    log_success "Prometheus installed successfully!"
}

install_superset() {
    log_info "Installing Apache Superset..."

    # Check if Superset is already installed
    if helm list -n $NAMESPACE | grep -q "superset"; then
        log_info "Superset is already installed. Continuing..."
        return 0
    fi

    # Add Helm repositories for Superset
    helm repo add superset https://apache.github.io/superset
    helm repo update

    # Install Superset
    # TODO: we're installing specific version, latest caused issue https://github.com/apache/superset/discussions/31431
    helm install superset superset/superset \
        --namespace $NAMESPACE \
        --values helm/superset/values.yaml \
        --version 0.14.3 \
        --wait --timeout=300s

    # Verify installation
    kubectl wait --for=condition=available deployment/superset -n $NAMESPACE --timeout=300s

    log_success "Apache Superset installed successfully!"
}

ingest_datasources() {
    log_info "Starting Wikipedia data ingestion..."

    kubectl apply -n $NAMESPACE -f manifests/ingest-wikipedia.yaml
    kubectl apply -n $NAMESPACE -f manifests/ingest-koalas.yaml

    log_info "Wikipedia and Koalas ingestion tasks submitted to Druid"
    log_info "You can check ingestion status in the Druid console under Tasks"

    log_success "Ingestion initiated"
}

get_access_info() {
    echo
    echo -e "${GREEN}=== Druid Cluster Setup Complete ===${NC}"
    echo
    echo "To access services:"
    echo
    echo "1. Druid:"
    echo -e "   ${YELLOW}kubectl port-forward -n druid svc/druid-druid-cluster-routers 8088${NC}"
    echo -e "   Open: ${YELLOW}http://localhost:8088${NC}"
    echo
    echo "2. MinIO Console:"
    echo -e "   ${YELLOW}kubectl port-forward -n druid svc/minio-console 8089:9090${NC}"
    echo -e "   Open: ${YELLOW}http://localhost:8089${NC} (credentials: minio/minio123)"
    echo
    echo "3. Superset Dashboard:"
    echo -e "   ${YELLOW}kubectl port-forward -n druid svc/superset 8090:8088${NC}"
    echo -e "   Open: ${YELLOW}http://localhost:8090${NC} (credentials: admin/admin)"
    echo
    echo "4. Prometheus:"
    echo -e "   ${YELLOW}kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090${NC}"
    echo -e "   Open: ${YELLOW}http://localhost:9090${NC}"
    echo
    echo "5. Grafana:"
    echo -e "   ${YELLOW}kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80${NC}"
    echo -e "   Open: ${YELLOW}http://localhost:3000/explore${NC} (credentials: admin/admin)"
    echo -e "   Example query: ${BLUE}druid_segment_size{}${NC}"
    echo
    echo -e "${GREEN}Happy querying with Apache Druid, Superset, and monitoring with Prometheus!${NC}"
    echo
}

main() {
    log_info "Starting Apache Druid on Kubernetes setup..."

    log_header "Kind cluster"
    check_prerequisites
    create_kind_cluster

    log_header "MinIO"
    install_minio_operator
    deploy_minio

    log_header "Druid"
    install_druid_operator
    deploy_zookeeper
    deploy_postgresql
    deploy_druid_cluster
    ingest_datasources

    log_header "Monitoring"
    install_prometheus

    wait_for_druid_cluster
    wait_for_prometheus

    log_header "Superset"
    install_superset

    get_access_info

    log_success "Setup completed! Check the access information above."
}

# Check if running as main script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
