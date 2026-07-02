#!/bin/bash
set -e

RESOURCE_GROUP="rg-bifrost-final-v6"
REGION="japaneast"

# O script descobre a sua própria localização, para funcionar
# independentemente de onde deres 'git clone' no Cloud Shell.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/terraform"
BACKEND_DIR="$SCRIPT_DIR/bifrost-backend"      # <-- ajusta aqui se a tua pasta se chamar "bitfrost-backend"
FRONTEND_DIR="$SCRIPT_DIR/bifrost-frontend"

echo "========================================================================="
echo "🚀 INICIANDO DEPLOY BIFROST - AUTOMATIZAÇÃO TOTAL (SOLO)"
echo "========================================================================="

cd "$TERRAFORM_DIR"

# O estado do Terraform não é apagado para proteger a VM e a DB já criadas.
terraform init

echo "[+] A orquestrar infraestrutura (inclui agora o Azure Container Registry)..."
terraform apply -var="location=$REGION" -var="rg_name=$RESOURCE_GROUP" -auto-approve

echo "[+] A extrair variáveis dinâmicas..."
STORAGE_NAME=$(az storage account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
COSMOS_NAME=$(az cosmosdb list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
FUNCTION_NAME=$(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
APP_SERVICE_NAME=$(az webapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
ACR_NAME=$(az acr list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)

STORAGE_CONN=$(az storage account show-connection-string --name "$STORAGE_NAME" --resource-group $RESOURCE_GROUP --query connectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list --name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "[+] A garantir tabelas NoSQL (Cosmos DB)..."
az cosmosdb sql database create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --name "bifrost-db" > /dev/null 2>&1 || true
az cosmosdb sql container create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --database-name "bifrost-db" --name "relatorios" --partition-key-path "/id" > /dev/null 2>&1 || true

echo "[+] A configurar variáveis Serverless e CORS..."
az functionapp config appsettings set --name "$FUNCTION_NAME" --resource-group $RESOURCE_GROUP --settings COSMOS_DB_CONNECTION_STRING="$COSMOS_CONN" AzureWebJobsStorage="$STORAGE_CONN" > /dev/null
APP_URL="https://$APP_SERVICE_NAME.azurewebsites.net"
az functionapp cors add --resource-group $RESOURCE_GROUP --name "$FUNCTION_NAME" --allowed-origins "$APP_URL" > /dev/null

echo "[+] A instalar dependências do Backend (node_modules não vem do Git)..."
cd "$BACKEND_DIR"
npm install --omit=dev

echo "[+] A publicar código do Backend (Azure Function)..."
func azure functionapp publish "$FUNCTION_NAME" --javascript

echo "[+] A preparar cópia temporária do Frontend para injeção de valores dinâmicos..."
API_URL="https://$FUNCTION_NAME.azurewebsites.net/api/ReconEngine"
VM_IP=$(az network public-ip show --resource-group $RESOURCE_GROUP --name ip-alvo-bifrost --query ipAddress -o tsv)

# IMPORTANTE: a injeção acontece numa cópia temporária, NUNCA no
# bifrost-frontend/index.html rastreado pelo Git. Se mexêssemos no
# ficheiro original, ficava "sujo" no working tree depois de cada deploy
# e bloqueava silenciosamente o próximo 'git pull'.
BUILD_DIR=$(mktemp -d)
cp -r "$FRONTEND_DIR"/. "$BUILD_DIR"/
sed -i "/BIFROST_TARGET_API_INJECTION/{n;s|const API_URL = .*|const API_URL = '$API_URL';|}" "$BUILD_DIR/index.html"
sed -i "/BIFROST_VM_IP_INJECTION/{n;s|const DEFAULT_TARGET_IP = .*|const DEFAULT_TARGET_IP = '$VM_IP';|}" "$BUILD_DIR/index.html"

echo "[+] A construir a imagem no Azure Container Registry (az acr build - sem Docker local)..."
az acr build --registry "$ACR_NAME" --image web-bifrost-frontend:latest "$BUILD_DIR"
rm -rf "$BUILD_DIR"

echo "[+] A apontar a App Service para a nova imagem e a forçar novo pull..."
az webapp config container set \
  --resource-group $RESOURCE_GROUP \
  --name "$APP_SERVICE_NAME" \
  --container-image-name "$ACR_NAME.azurecr.io/web-bifrost-frontend:latest" \
  --container-registry-url "https://$ACR_NAME.azurecr.io" > /dev/null

echo "[+] A reiniciar o servidor para aplicar alterações..."
az webapp restart --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" > /dev/null

echo "========================================================================="
echo "🎯 PROJETO BIFROST: RED TEAM CLOUD ONLINE"
echo "========================================================================="
echo "👉 Dashboard URL: $APP_URL"
echo "Aguarde ~60-90 segundos para o Azure completar o pull da nova imagem."
echo "========================================================================="
