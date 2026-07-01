#!/bin/bash
# =========================================================================
# BIFROST SYSTEM - ORCHESTRATION & DEPLOYMENT SCRIPT (CN EVALUATION)
# =========================================================================
set -e

RESOURCE_GROUP="rg-bifrost-final"

echo "========================================================================="
echo "🎯 STARTING BIFROST INFRASTRUCTURE ORCHESTRATION"
echo "========================================================================="

echo "[+] Inicializando infraestrutura com Terraform (IaC)..."
cd ~/project-bifrost/terraform
terraform init
terraform apply -auto-approve

echo "[+] Mapeando recursos provisionados dinamicamente..."
STORAGE_NAME=$(az storage account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
COSMOS_NAME=$(az cosmosdb list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
FUNCTION_NAME=$(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)

echo "    [✔] Storage Detetado: $STORAGE_NAME"
echo "    [✔] CosmosDB Detetado: $COSMOS_NAME"
echo "    [✔] Function App Detetada: $FUNCTION_NAME"

echo "[+] Extraindo chaves e Connection Strings em tempo real..."
STORAGE_CONN=$(az storage account show-connection-string --name "$STORAGE_NAME" --resource-group $RESOURCE_GROUP --query connectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list --name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "[+] Assegurando integridade do Modelo de Dados NoSQL..."
az cosmosdb sql database create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --name "bifrost-db" || true
az cosmosdb sql container create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --database-name "bifrost-db" --name "relatorios" --partition-key-path "/id" || true

echo "[+] Injetando Variáveis de Ambiente na Azure Function..."
az functionapp config appsettings set --name "$FUNCTION_NAME" --resource-group $RESOURCE_GROUP --settings COSMOS_DB_CONNECTION_STRING="$COSMOS_CONN" AzureWebJobsStorage="$STORAGE_CONN" > /dev/null

echo "[+] Configurando permissões de CORS para isolamento do Frontend..."
az functionapp cors add --resource-group $RESOURCE_GROUP --name "$FUNCTION_NAME" --allowed-origins "https://$STORAGE_NAME.z28.web.core.windows.net" > /dev/null

echo "[+] Compilando e publicando Backend Serverless..."
cd ~/project-bifrost/bifrost-backend
func azure functionapp publish "$FUNCTION_NAME" --javascript

echo "[+] Compilando e atualizando Frontend Estático..."
API_URL="https://$FUNCTION_NAME.azurewebsites.net/api/ReconEngine"
sed -i "const API_URL = .*/const API_URL = '$API_URL';/g" ~/project-bifrost/bifrost-frontend/index.html

az storage blob service-properties update --account-name "$STORAGE_NAME" --static-website true --index-document index.html > /dev/null
az storage blob upload --account-name "$STORAGE_NAME" --container-name '$web' --file ~/project-bifrost/bifrost-frontend/index.html --name index.html --overwrite true
az storage blob upload --account-name "$STORAGE_NAME" --container-name '$web' --file ~/project-bifrost/bifrost-frontend/logo.png --name logo.png --overwrite true

echo "========================================================================="
echo "🚀 SISTEMA BIFROST COM DEPLOY COMPLETO NA CLOUD"
echo "========================================================================="
echo "👉 Dashboard URL (Abra no browser):"
echo "   https://$STORAGE_NAME.z28.web.core.windows.net/"
echo "========================================================================="