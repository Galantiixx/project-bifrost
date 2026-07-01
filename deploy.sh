#!/bin/bash
# =========================================================================
# BIFROST SYSTEM - RESILIENT MULTI-REGION DEV-OPS ORCHESTRATION
# =========================================================================
set -e

RESOURCE_GROUP="rg-bifrost-final"

# Lista de regiões europeias por ordem de prioridade para testar
REGIONS=("westeurope" "northeurope" "francecentral" "uksouth")

echo "========================================================================="
echo "🎯 STARTING RESILIENT BIFROST INFRASTRUCTURE ORCHESTRATION"
echo "========================================================================="

# Inicializar o Terraform uma única vez
cd ~/project-bifrost/terraform
terraform init

DEPLOY_SUCCESS=false

for REGION in "${REGIONS[@]}"; do
    echo "[*] A tentar fazer o deploy na região: $REGION..."
    
    # Executa o Terraform injetando a região dinamicamente por variável
    if terraform apply -var="location=$REGION" -auto-approve; then
        echo "[+] Sucesso! Infraestrutura criada em $REGION."
        DEPLOY_SUCCESS=true
        CURRENT_REGION=$REGION
        break
    else
        echo "[⚠️] Falha de quotas ou recursos em $REGION. A limpar e a saltar para a próxima..."
        # Apaga o grupo de recursos que falhou a meio para libertar nomes e lixo
        az group delete --name $RESOURCE_GROUP --yes --no-wait || true
        # Limpa o estado local do Terraform para evitar o erro de inconsistência
        rm -f terraform.tfstate terraform.tfstate.backup
    fi
done

if [ "$DEPLOY_SUCCESS" = false ]; then
    echo "❌ [ERRO] Todas as regiões da Europa estão saturadas neste momento. Tenta mais tarde."
    exit 1
fi

echo "[+] Extraindo recursos e mapeamentos dinâmicos..."
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
echo "🚀 ECOSSISTEMA BIFROST ONLINE (REGIÃO AFETADA: $CURRENT_REGION)"
echo "========================================================================="
echo "👉 Dashboard URL:"
echo "   $APP_URL"
echo "========================================================================="