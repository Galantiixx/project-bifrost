#!/bin/bash
set -e

RESOURCE_GROUP="rg-bifrost-final-v2"
REGION="eastus"

echo "[+] Limpando estado local..."
rm -rf terraform/.terraform terraform/terraform.tfstate

echo "[+] Iniciando Deploy..."
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve -var="rg_name=$RESOURCE_GROUP" -var="location=$REGION"

echo "[+] Deploy Concluído com sucesso na região $REGION"
