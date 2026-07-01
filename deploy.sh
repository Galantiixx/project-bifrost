#!/bin/bash
set -e

RESOURCE_GROUP="rg-bifrost-final"
REGION="denmarkeast"

echo "========================================================================="
echo "🚀 INICIANDO DEPLOY DIRETO BIFROST - RETA FINAL"
echo "========================================================================="

cd ~/project-bifrost/terraform

# ATENÇÃO: Ficheiros de estado NÃO SÃO APAGADOS para garantir que a VM e Cosmos já criados não se perdem.
terraform init

echo "[+] A aplicar infraestrutura (Atualizando apenas a Azure Function em falta)..."
terraform apply -var="location=$REGION" -var="rg_name=$RESOURCE_GROUP" -auto-approve

echo "[+] A extrair credenciais dinâmicas da infraestrutura..."
STORAGE_NAME=$(az storage account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
COSMOS_NAME=$(az cosmosdb list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
FUNCTION_NAME=$(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
APP_SERVICE_NAME=$(az webapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)

STORAGE_CONN=$(az storage account show-connection-string --name "$STORAGE_NAME" --resource-group $RESOURCE_GROUP --query connectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list --name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "[+] A garantir tabelas NoSQL (Cosmos DB)..."
az cosmosdb sql database create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --name "bifrost-db" || true
az cosmosdb sql container create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --database-name "bifrost-db" --name "relatorios" --partition-key-path "/id" || true

echo "[+] A injetar configurações na Azure Function..."
az functionapp config appsettings set --name "$FUNCTION_NAME" --resource-group $RESOURCE_GROUP --settings COSMOS_DB_CONNECTION_STRING="$COSMOS_CONN" AzureWebJobsStorage="$STORAGE_CONN" > /dev/null

echo "[+] A aplicar permissões de CORS..."
APP_URL="https://$APP_SERVICE_NAME.azurewebsites.net"
az functionapp cors add --resource-group $RESOURCE_GROUP --name "$FUNCTION_NAME" --allowed-origins "$APP_URL" > /dev/null

echo "[+] A publicar código do Backend Serverless..."
cd ~/project-bifrost/bifrost-backend
func azure functionapp publish "$FUNCTION_NAME" --javascript

echo "[+] A injetar endpoint dinâmico no Frontend..."
API_URL="https://$FUNCTION_NAME.azurewebsites.net/api/ReconEngine"
sed -i "/BIFROST_TARGET_API_INJECTION/{n;s|const API_URL = .*|const API_URL = '$API_URL';|}" ~/project-bifrost/bifrost-frontend/index.html

echo "[+] A carregar Frontend para o App Service..."
cd ~/project-bifrost/bifrost-frontend
zip -r frontend.zip index.html logo.png Dockerfile > /dev/null
az webapp deployment source config-zip --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --src frontend.zip > /dev/null
rm frontend.zip

echo "========================================================================="
echo "🎯 PROJETO BIFROST CONCLUÍDO COM SUCESSO"
echo "========================================================================="
echo "👉 Dashboard URL: $APP_URL"
echo "========================================================================="