# Apache Druid on Kubernetes with kind

This repository provides a complete setup guide for running Apache Druid locally using Kubernetes-in-Docker (kind) and the Druid Operator, based on https://github.com/datainfrahq/druid-operator

Setup:
```
./setup.sh
```
The script is idempotent, so can be rerun again in case something failed/timed out.

Clean up:
```
kind delete cluster --name druid-operator
```
