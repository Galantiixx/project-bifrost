#!/bin/bash
set -e

RESOURCE_GROUP_BASE="rg-bifrost"
CANDIDATE_REGIONS=("northeurope" "francecentral" "uksouth")

echo "========================================================================="
echo "🎯 BIFROST: A ORQUESTRAR INFRAESTRUTURA NAS REGIÕES ALTERNATIVAS"
echo "========================================================================="

TARGET_REGION=""

for REGION in "${CANDIDATE_REGIONS[@]}"; do
    echo "[*] A testar deploy direto em: $REGION..."
    RESOURCE_GROUP="${RESOURCE_GROUP_BASE}-${REGION}"
    
    cd ~/project-bifrost/terraform
    
    # Limpar estados antigos E ficheiros de lock que travam os providers
    rm -f terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl
    rm -rf .terraform
    
    # Forçar a inicialização limpa dos providers (azurerm e random) nesta tentativa
    terraform init
    
    # Tenta aplicar. Se der certo, quebra o loop.
    if terraform apply -var="location=$REGION" -var="rg_name=$RESOURCE_GROUP" -auto-approve; then
        echo " -> ✅ DEPLOY COM SUCESSO EM $REGION!"
        TARGET_REGION=$REGION
        FINAL_RG=$RESOURCE_GROUP
        break
    else
        echo " -> ❌ Sem recursos em $REGION. A limpar e a saltar..."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait || true
    fi
done

if [ -z "$TARGET_REGION" ]; then
    echo "❌ [ERRO CRÍTICO] Falha total em todas as regiões europeias."
    exit 1
fi

RESOURCE_GROUP=$FINAL_RG
echo "[+] Extraindo recursos e mapeamentos dinâmicos do grupo $RESOURCE_GROUP..."
STORAGE_NAME=$(az storage account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
COSMOS_NAME=$(az cosmosdb list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
FUNCTION_NAME=$(az functionapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
APP_SERVICE_NAME=$(az webapp list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)

STORAGE_CONN=$(az storage account show-connection-string --name "$STORAGE_NAME" --resource-group $RESOURCE_GROUP --query connectionString -o tsv)
COSMOS_CONN=$(az cosmosdb keys list --name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --type connection-strings --query "connectionStrings[0].connectionString" -o tsv)

echo "[+] Garantindo integridade das tabelas NoSQL (Cosmos DB)..."
az cosmosdb sql database create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --name "bifrost-db" || true
az cosmosdb sql container create --account-name "$COSMOS_NAME" --resource-group $RESOURCE_GROUP --database-name "bifrost-db" --name "relatorios" --partition-key-path "/id" || true

echo "[+] Vinculando credenciais criptográficas à Azure Function..."
az functionapp config appsettings set --name "$FUNCTION_NAME" --resource-group $RESOURCE_GROUP --settings COSMOS_DB_CONNECTION_STRING="$COSMOS_CONN" AzureWebJobsStorage="$STORAGE_CONN" > /dev/null

echo "[+] Configurando políticas de CORS para o Azure App Service..."
APP_URL="https://$APP_SERVICE_NAME.azurewebsites.net"
az functionapp cors add --resource-group $RESOURCE_GROUP --name "$FUNCTION_NAME" --allowed-origins "$APP_URL" > /dev/null

echo "[+] Compilando e publicando Backend Serverless..."
cd ~/project-bifrost/bifrost-backend
func azure functionapp publish "$FUNCTION_NAME" --javascript

echo "[+] Injetando Endpoint Dinâmico no Frontend..."
API_URL="https://$FUNCTION_NAME.azurewebsites.net/api/ReconEngine"
sed -i "/BIFROST_TARGET_API_INJECTION/{n;s|const API_URL = .*|const API_URL = '$API_URL';|}" ~/project-bifrost/bifrost-frontend/index.html

echo "[+] Realizando Deployment do Frontend via Azure App Service Container..."
cd ~/project-bifrost/bifrost-frontend
zip -r frontend.zip index.html logo.png Dockerfile > /dev/null
az webapp deployment source config-zip --resource-group $RESOURCE_GROUP --name "$APP_SERVICE_NAME" --src frontend.zip > /dev/null
rm frontend.zip

echo "========================================================================="
echo "🚀 ECOSSISTEMA BIFROST ONLINE (REGIÃO AFETADA: $TARGET_REGION)"
echo "========================================================================="
echo "👉 Dashboard URL:"
echo "   $APP_URL"
echo "========================================================================="