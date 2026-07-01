#!/bin/bash
set -e

RESOURCE_GROUP="rg-bifrost-final"
REGION="denmarkeast"

echo "========================================================================="
echo "🚀 INICIANDO DEPLOY BIFROST - AUTOMATIZAÇÃO TOTAL (SOLO)"
echo "========================================================================="

cd ~/project-bifrost/terraform

# O estado do Terraform não é apagado para proteger a VM e a DB já criadas.
terraform init

echo "[+] A orquestrar infraestrutura..."
terraform apply -var="location=$REGION" -var="rg_name=$RESOURCE_GROUP" -auto-approve

echo "[+] A extrair variáveis dinâmicas..."
STORAGE_NAME=$(az storage account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
COSMOS_NAME=$(az cosmosdb list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
FUNCTION_NAME=$(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
APP_SERVICE_NAME=$(az webapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)

STORAGE_CONN=$(az storage account show-connection-string --name "$STORAGE_NAME" --resource-group $RESOURCE_GROUP --query connectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list --name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "[+] A garantir tabelas NoSQL (Cosmos DB)..."
az cosmosdb sql database create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --name "bifrost-db" > /dev/null 2>&1 || true
az cosmosdb sql container create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --database-name "bifrost-db" --name "relatorios" --partition-key-path "/id" > /dev/null 2>&1 || true

echo "[+] A configurar variáveis Serverless e CORS..."
az functionapp config appsettings set --name "$FUNCTION_NAME" --resource-group $RESOURCE_GROUP --settings COSMOS_DB_CONNECTION_STRING="$COSMOS_CONN" AzureWebJobsStorage="$STORAGE_CONN" > /dev/null
APP_URL="https://$APP_SERVICE_NAME.azurewebsites.net"
az functionapp cors add --resource-group $RESOURCE_GROUP --name "$FUNCTION_NAME" --allowed-origins "$APP_URL" > /dev/null

echo "[+] A publicar código do Backend (Azure Function)..."
cd ~/project-bifrost/bifrost-backend
func azure functionapp publish "$FUNCTION_NAME" --javascript

echo "[+] A injetar endpoint dinâmico no Frontend..."
API_URL="https://$FUNCTION_NAME.azurewebsites.net/api/ReconEngine"
sed -i "/BIFROST_TARGET_API_INJECTION/{n;s|const API_URL = .*|const API_URL = '$API_URL';|}" ~/project-bifrost/bifrost-frontend/index.html

echo "[+] A preparar pacote do Frontend e Script Nativo do Docker..."
cd ~/project-bifrost/bifrost-frontend

# 1. CRIAMOS O SCRIPT DE ARRANQUE DENTRO DA PASTA DO TEU CÓDIGO
cat << 'EOF' > startup.sh
#!/bin/sh
echo "A sincronizar ficheiros HTML com o Nginx..."
cp -a /home/site/wwwroot/. /usr/share/nginx/html/
echo "A arrancar o servidor Web..."
exec nginx -g "daemon off;"
EOF

chmod +x startup.sh

# 2. EMPACOTAR TUDO (CÓDIGO + SCRIPT DE ARRANQUE)
rm -f frontend.zip
zip -r frontend.zip . > /dev/null

echo "[+] A executar ZipDeploy automatizado..."
az webapp deploy --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --src-path frontend.zip --type zip > /dev/null

echo "[+] A ligar o Contentor Docker (Nginx) ao script..."
# Ativamos o disco persistente da Azure
az webapp config appsettings set --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --settings WEBSITES_ENABLE_APP_SERVICE_STORAGE=true > /dev/null
# Dizemos ao Docker para simplesmente executar o script que enviámos (adeus problemas de aspas)
az webapp config set --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --startup-file "sh /home/site/wwwroot/startup.sh" > /dev/null

echo "[+] A reiniciar o servidor para aplicar alterações..."
az webapp restart --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" > /dev/null

echo "========================================================================="
echo "🎯 PROJETO BIFROST: RED TEAM CLOUD ONLINE"
echo "========================================================================="
echo "👉 Dashboard URL: $APP_URL"
echo "Aguarde ~60 segundos para o Docker inicializar antes de aceder."
echo "========================================================================="