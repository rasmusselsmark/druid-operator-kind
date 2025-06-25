# Apache Druid on Kubernetes with kind

This repository provides a complete setup guide for running Apache Druid locally using Kubernetes-in-Docker (kind) and the Druid Operator, based on https://github.com/datainfrahq/druid-operator

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
Follow instructions, Druid will be available at http://localhost:8088 (after port-forwarding).

The `setup.sh` script is idempotent, so can be rerun again in case something failed/timed out.

### Clean up
```
kind delete cluster --name druid
```
