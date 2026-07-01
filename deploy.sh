#!/bin/bash
# =========================================================================
# BIFROST SYSTEM - PRE-FLIGHT SKU AVAILABILITY CHECKER
# =========================================================================
set -e

RESOURCE_GROUP_BASE="rg-bifrost"
# Lista de regiões candidatas na Europa para fazermos o Varredura de Disponibilidade
CANDIDATE_REGIONS=("westeurope" "northeurope" "francecentral" "uksouth")

echo "========================================================================="
echo "🔍 BIFROST PRE-FLIGHT: À PROCURA DE CAPACIDADE NA AZURE..."
echo "========================================================================="

TARGET_REGION=""

for REGION in "${CANDIDATE_REGIONS[@]}"; do
    echo -n "[*] A verificar restrições e SKUs em '$REGION'..."
    
    # Consulta a API da Azure para ver se o tamanho B1s está restrito ou indisponível nesta região
    SKU_CHECK=$(az vm list-skus --location "$REGION" --size "Standard_B1s" --query "[0].restrictions" -o tsv 2>/dev/null || echo "NotAvailable")
    
    # Se o retorno for vazio, significa que NÃO há restrições físicas no Data Center
    if [ -z "$SKU_CHECK" ]; then
        echo " -> ✅ DISPONÍVEL!"
        TARGET_REGION=$REGION
        break
    else
        echo " -> ❌ ESGOTADO/RESTREITO"
    fi
done

if [ -z "$TARGET_REGION" ]; then
    echo "❌ [ERRO CRÍTICO] Nenhuma das regiões europeias tem capacidade para o SKU Standard_B1s de momento."
    exit 1
fi

RESOURCE_GROUP="${RESOURCE_GROUP_BASE}-${TARGET_REGION}"
echo ""
echo "========================================================================="
echo "🎯 REGIÃO ESCOLHIDA: $TARGET_REGION | RESOURCE GROUP: $RESOURCE_GROUP"
echo "========================================================================="

cd ~/project-bifrost/terraform
rm -f terraform.tfstate terraform.tfstate.backup # Limpar lixo de estados inconsistentes anteriores
terraform init

echo "[+] A lançar infraestrutura à primeira..."
terraform apply -var="location=$TARGET_REGION" -var="rg_name=$RESOURCE_GROUP" -auto-approve

echo "[+] Extraindo mapeamentos dinâmicos..."
STORAGE_NAME=$(az storage account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
COSMOS_NAME=$(az cosmosdb list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
FUNCTION_NAME=$(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
APP_SERVICE_NAME=$(az webapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)

STORAGE_CONN=$(az storage account show-connection-string --name "$STORAGE_NAME" --resource-group $RESOURCE_GROUP --query connectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list --name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "[+] A configurar base NoSQL Cosmos DB..."
az cosmosdb sql database create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --name "bifrost-db" || true
az cosmosdb sql container create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --database-name "bifrost-db" --name "relatorios" --partition-key-path "/id" || true

echo "[+] A injetar credenciais na Azure Function..."
az functionapp config appsettings set --name "$FUNCTION_NAME" --resource-group $RESOURCE_GROUP --settings COSMOS_DB_CONNECTION_STRING="$COSMOS_CONN" AzureWebJobsStorage="$STORAGE_CONN" > /dev/null

echo "[+] Configurando CORS para o App Service..."
APP_URL="https://$APP_SERVICE_NAME.azurewebsites.net"
az functionapp cors add --resource-group $RESOURCE_GROUP --name "$FUNCTION_NAME" --allowed-origins "$APP_URL" > /dev/null

echo "[+] Publicando Backend Serverless..."
cd ~/project-bifrost/bifrost-backend
func azure functionapp publish "$FUNCTION_NAME" --javascript

echo "[+] Sincronizando Endpoint no Frontend..."
API_URL="https://$FUNCTION_NAME.azurewebsites.net/api/ReconEngine"
sed -i "/BIFROST_TARGET_API_INJECTION/{n;s|const API_URL = .*|const API_URL = '$API_URL';|}" ~/project-bifrost/bifrost-frontend/index.html

echo "[+] A subir Frontend Dockerizado para o App Service..."
cd ~/project-bifrost/bifrost-frontend
zip -r frontend.zip index.html logo.png Dockerfile > /dev/null
az webapp deployment source config-zip --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --src frontend.zip > /dev/null
rm frontend.zip

echo "========================================================================="
echo "🚀 ECOSSISTEMA BIFROST ONLINE À PRIMEIRA"
echo "========================================================================="
echo "👉 URL do Dashboard: $APP_URL"
echo "========================================================================="