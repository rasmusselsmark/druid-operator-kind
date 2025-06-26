# Apache Druid on Kubernetes with kind

This repository provides a setup guide for running Apache Druid locally using Kubernetes-in-Docker (kind) and the Druid Operator, using https://github.com/datainfrahq/druid-operator and https://github.com/minio/operator (local S3 bucket)

![Apache Druid](docs/images/druid.png)

### Prerequisites

Setup script uses these tools:

* [docker](https://docs.docker.com/get-docker/)
* [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
* [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
* [helm](https://helm.sh/docs/intro/install/)

### Setup
```
./setup.sh
```
Follow instructions, Druid will be available at http://localhost:8088 and Superset on http://localhost:8080 (after port-forwarding).

The `setup.sh` script is idempotent, so can be rerun again in case something failed/timed out.

### Clean up
```
kind delete cluster --name druid
```
