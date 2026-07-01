#!/bin/bash
set -e

RESOURCE_GROUP="rg-bifrost-final"
REGION="denmarkeast"

echo "========================================================================="
echo "🚀 INICIANDO DEPLOY BIFROST - SOLO RED TEAM MODE"
echo "========================================================================="

cd ~/project-bifrost/terraform

# ATENÇÃO: Ficheiros de estado NÃO SÃO APAGADOS para proteger os recursos já criados.
terraform init

echo "[+] A aplicar infraestrutura..."
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

echo "[+] A carregar Frontend injetado para o App Service (via ZipDeploy automatizado)..."
cd ~/project-bifrost/bifrost-frontend
rm -f frontend.zip
zip -r frontend.zip . > /dev/null

# Usa o novo comando deploy (que não bloqueia no Kudu) de forma totalmente automatizada
az webapp deploy --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --src-path frontend.zip --type zip > /dev/null

echo "[+] A mapear o Docker Container (Nginx) para o código fonte..."
# Ativa a partilha de disco e força o Nginx a ler a pasta correta sem falhas
az webapp config appsettings set --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --settings WEBSITES_ENABLE_APP_SERVICE_STORAGE=true > /dev/null
az webapp config set --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --startup-file "rm -rf /usr/share/nginx/html && ln -s /home/site/wwwroot /usr/share/nginx/html && nginx -g 'daemon off;'" > /dev/null

echo "[+] A reiniciar App Service para aplicar a injeção do código..."
az webapp restart --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" > /dev/null

echo "========================================================================="
echo "🎯 PROJETO BIFROST CONCLUÍDO E TOTALMENTE OPERACIONAL"
echo "========================================================================="
echo "👉 Dashboard URL: $APP_URL"
echo "========================================================================="